#! /usr/bin/env bash
############################################################
# A simpler rewrite of av1master client.sh for prototyping #
############################################################
set -euo pipefail
IFS=$'\n\t'

base_url="$1"
version="0.13.0"

#################
# $1 - URL      #
# $2 - output   #
# file - output #
#################
download() {
    curl -L "$1" -o "$2"
}

#duration=3
#progressive_back_off() {
#    if [[ duration -lt 300 ]]; then
#        duration=$((duration * 2))
#    else
#        duration=300
#    fi
#}

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
            -i '$file' '$ffmpeg_options' -f yuv4mpegpipe - | aomenc - '$aom_options' \
            --pass=1 --passes=2 --fpf='$file'.fpf --ivf -o '$file'.out.ivf'
        retval=$?
        if [[ $retval -ne 0 ]]; then
            echo "Error running aomenc pass 1 of 2" >&2
            echo "" >&2
            return 1
        fi

        eval 'ffmpeg -nostats -hide_banner -loglevel warning \
            -i '$file' '$ffmpeg_options' -f yuv4mpegpipe - | aomenc - '$aom_options' \
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
            "[0:v][1:v]libvmaf=model_path=$MODEL_PATH/share/model/vmaf_v0.6.1.pkl:log_fmt=json:log_path=$encode.vmaf.json" -f null - 2>/dev/null >/dev/null
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

##################################
# STDIN - vmaf json              #
# STDOUT - per frame json column #
##################################
extract_vmaf() {
    jq '.frames[].metrics.vmaf'
}

##################################################
# stdin - vmaf json                              #
# $1 - calculation -  one of mean,median,perc:XX #
# stdout - result                                #
##################################################
percentille() {
    extract_vmaf | datamash $1 1
}

#####################
# STDIN - vmaf json #
# $1 - output path  #
# file - $1         #
#####################
graph_vmaf() {
    extract_vmaf | eplot -t VMAF -P -o "$1" 2>/dev/null
}

####################
# $1 - input       #
# $2 - target vmaf #
# $3 - minimum q   #
# $4 - maximum q   #
# STDOUT - Q value #
####################
find_q() {
    echo "finding q" >&2
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
            echo "highest q over target is:" >&2
            echo $best_q
            break
        fi;
        last_q=$q
        echo "trying q: $q" >&2

        encode_aomenc_single_pass "$input" "-q --end-usage=q --cpu-used=6 --cq-level=$q" ""
        vmaf=`check_vmaf "$input".out.ivf "$input" | percentille "perc:25"`
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

test() {
    download "https://pomf.dodsorf.as/f/exfapb.mkv" "test-001.mkv"
    q=`find_q "test-001.mkv" "94" "25" "40"`
    echo "$q"
    encode_aomenc_two_pass "test-001.mkv" "-q --end-usage=q --cpu-used=4 --cq-level=$q" ""
    vmaf=`check_vmaf "test-001.mkv.out.ivf" "test-001.mkv"`
    rm test-001.mkv
    echo $vmaf | graph_vmaf "test-001.graph.png"
}

av1master_job() {
    set +e
        job=`curl -s -L "$base_url"/request_job | jq`
        retval=$?
    set -e
    if [[ $job = "null" ]] || [ $retval -ne 0 ]; then
        echo "No Jobs Available ¯\_(ツ)_/¯" >&2
        return 1
    fi
    job_id=`echo "$job" | jq -r .id`
    set +e
        curl -s "$base_url"/edit_status/"$job_id"/reserved
    set -e

    source=`echo $job | jq -r .description.file_url`
    sourceext=${source##*.}
    name=`echo $job | jq -r .description.file_name`
    input="$name.$job_id.$sourceext"

    set +e
        download $source $input
        retval=$?
    set -e
    if [ $retval -ne 0 ]; then
        echo "Could not Download file!" >&2
        curl -s -L "$base_url"/edit_status/"$job_id"/error || true
        return 2
    fi

    height=`echo $job | jq -r .description.resolution[0]`
    width=`echo $job | jq -r .description.resolution[1]`

    options=`echo $job | jq .description.options.AOMENC`
    aomenco=`echo $options | jq -r .aomenc`
    ffmpego=`echo $options | jq -r .ffmpeg`

    pix_fmt=`echo $options | jq -r .pix_fmt`
    if [[ $pix_fmt = "YV12" ]]; then
        ffpix="yuv12p"
        aompix="--yv12"
    elif [[ $pix_fmt = "I420" ]]; then
        ffpix="yuv420p"
        aompix="--i420"
    elif [[ $pix_fmt = "I422" ]]; then
        ffpix="yuv422p"
        aompix="--i422"
    elif [[ $pix_fmt = "I444" ]]; then
        ffpix="yuv444p"
        aompix="--i444"
    fi

    encode_aomenc_two_pass "$input" "$aomenco $aompix --width=$width --height=$height" "$ffmpego -vf scale=$width:$height -pix_fmt $ffpix"

    rm "$input"

    curl -s -L "$base_url"/edit_status/"$job_id"/completed
    curl --data-binary @"$input".out.ivf "$base_url"/upload/"$job_id"
    rm "$input".out.ivf
}

#test

while true; do
    sleep 30
    av1master_job
done