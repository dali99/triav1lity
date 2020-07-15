#! /usr/bin/env bash
############################################################
# A simpler rewrite of av1master client.sh for prototyping #
############################################################
set -euo pipefail
IFS=$'\n\t'


#########################
# $1 - file             #
# $2 - AOM Options      #
# $3 - FFMPEG Options   #
# files - $file.out.ivf #
#########################
encode_aomenc_two_pass() {
    file="$1"
    aom_options="$2"
    # Remove any character that isn't a letter, an underscore, a dash, or =
    # Hopefully "cleans" the commandline
    # so that you can't just take over a system
    # Still possible to misuse ffmpeg and aomenc to overwrite any file
    # the user running the program has access to.
    # THIS IS NOT SAFE
    # But it's something
    aom_options=${aom_options//[^a-zA-Z0-9_\- =]/}
    # Same story as above but also
    ffmpeg_options="$3"
    ffmpeg_options=${ffmpeg_options//[^a-zA-Z0-9_\- =:]/}

    set +e
        eval 'ffmpeg -nostats -hide_banner -loglevel warning \
            -i '$file' $ffmpeg_options -f yuv4mpegpipe - | aomenc - '$aom_options' \
            --pass=1 --passes=2 --fpf='$file'.fpf --ivf -o '$file'.out.ivf'
        retval=$?
        if [[ $retval -ne 0 ]]; then
            echo "Error running aomenc pass 1 of 2" >&2
            echo "" >&2
            return 1
        fi

        eval 'ffmpeg -nostats -hide_banner -loglevel warning \
            -i '$file' $ffmpeg_options -f yuv4mpegpipe - | aomenc - '$aom_options' \
            --pass=2 --passes=2 --fpf='$file'.fpf --ivf -o '$file'.out.ivf'
        retval=$?
        if [ $retval -ne 0 ]; then
            echo "Error running aomenc pass 2 of 2" >&2
            echo "" >&2
            return 2
        fi
    set -e

    rm -f "$file".fpf
    return 0
}

#########################
# $1 - file             #
# $2 - AOM Options      #
# $3 - FFMPEG Options   #
# files - $file.out.ivf #
#########################
encode_aomenc_single_pass() {
    file="$1"
    aom_options="$2"
    # Remove any character that isn't a letter, an underscore, a dash, or =
    # Hopefully "cleans" the commandline
    # so that you can't just take over a system
    # Still possible to misuse ffmpeg and aomenc to overwrite any file
    # the user running the program has access to.
    # THIS IS NOT SAFE
    # But it's something
    aom_options=${aom_options//[^a-zA-Z0-9_\- =]/}
    # Same story as above but also
    ffmpeg_options="$3"
    ffmpeg_options=${ffmpeg_options//[^a-zA-Z0-9_\- =:]/}

    set +e
        eval 'ffmpeg -nostats -hide_banner -loglevel warning \
            -i '$file' $ffmpeg_options -f yuv4mpegpipe - | aomenc - '$aom_options' \
            --passes=1 --ivf -o '$file'.out.ivf'
        retval=$?
        if [[ $retval -ne 0 ]]; then
            echo "Error running aomenc single pass encode" >&2
            echo "" >&2
            return $retval
        fi
    set -e
    return 0
}


##########################
# $1 - encode            #
# $2 - reference         #
# STDOUT - VMAF log JSON #
##########################
check_vmaf() {
    encode="$1"
    reference="$2"
    set +e
        ffmpeg -nostats -hide_banner -loglevel warning \
            -r 24 -i "$encode" -r 24 -i "$reference" -filter_complex \
            "[0:v][1:v]libvmaf=model_path=$MODEL_PATH/share/model/vmaf_v0.6.1.pkl:log_fmt=json:log_path=$encode.vmaf.json" -f null - >/dev/null
        retval=$?
        if [ $retval -ne 0 ]; then
            echo "Error running VMAF scan" >&2
            echo "" >&2
            return 1
        fi
        cat "$encode".vmaf.json
        rm "$encode".vmaf.json
    set -e
}

####################
# $1 - input       #
# $2 - target vmaf #
# $3 - minimum q   #
# $4 - maximum q   #
# STDOUT - Q value #
####################
find_q() {
    echo "finding q" > &2
    input="$1"
    target="$2"
    min_q="$3"
    max_q="$4"

    q="foo"

    last_q="bar"
    best_q="$min_q"

    while true; do
        echo "$min_q, $max_q" >&2
        q=`echo "($min_q + $max_q)/2" | bc`
        if [[ $q == $last_q ]]; then
            echo "highest q over target is:" > &2
            echo $best_q
            break
        fi;
        last_q=$q
        echo "trying q: $q" > >&2

        encode_aomenc_single_pass "$input" "-q --passes=1 --end-usage=q --cpu-used=6 --cq-level=$q" ""
        vmaf=`check_vmaf "$input".out.ivf "$input" | jq -r '."VMAF score"'`
        echo "vmaf: $vmaf" >&2

        result=`echo "$vmaf >= $target" | bc`
        if [[ $result -eq "1" ]]; then
            min_q=`echo $q - 1 | bc`
            if [[ $q -gt $best_q ]]; then
                best_q=$q
            fi
        elif [[ $result -eq "0" ]]; then
            max_q=`echo $q + 1 | bc`
        fi
    done
    rm "$input".out.ivf
}

find_q "$1" "94" "25" "40"