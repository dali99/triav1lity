#! /usr/bin/env bash
############################################################
# A simpler rewrite of av1master client.sh for prototyping #
############################################################
set -euo pipefail
IFS=$'\n\t'


#######################
# $1 - file           #
# $2 - AOM Options    #
# $3 - FFMPEG Options #
# $4 - do VMAF?       #
#######################
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
    ffmpeg_options=${ffmpego//[^a-zA-Z0-9_\- =:]/}
    # set to boolean
    doVMAF=$4

    set +e
        ffmpeg -nostats -hide_banner -loglevel warning \
            -i "$file" "$ffmpeg_options" -f yuv4mpegpipe - | aomenc - "$aom_options" \
            --pass=1 --passes=2 --fpf="$file".fpf --ivf -o "$file".out.ivf
        retval=$?
        if [[ $retval -ne 0 ]]; then
            echo "Error running aomenc pass 1 of 2" >&2
            curl -s -L "$base_url"/edit_status/"$job_id"/error || true
            echo "" >&2
            return 1
        fi

        ffmpeg -nostats -hide_banner -loglevel warning \
            -i "$file" "$ffmpeg_options" -f yuv4mpegpipe - | aomenc - "$aom_options" \
            --pass=1 --passes=2 --fpf="$file".fpf --ivf -o "$file".out.ivf
        retval=$?
        if [ $retval -ne 0 ]; then
            echo "Error running aomenc pass 2 of 2" >&2
            curl -s -L "$base_url"/edit_status/"$job_id"/error || true
            echo "" >&2
            return 2
        fi

        
        # This probably needs to be improved as well, so that it scales
        # and sets the framerate automatically. This will likely never
        # Actually get used though, so it's fine.
        if [[ doVMAF -eq true ]]; then
            ffmpeg -nostats -hide_banner -loglevel warning \
                -r 24 -i "$file".out.ivf -r 24 "$file" -filter_complex \
                "[0:v][1:v]libvmaf=log_fmt=json:log_path=$file.vmaf.json" -f null - >/dev/null
            retval=$?
            if [ $retval -ne 0 ]; then
                echo "Error running VMAF scan" >&2
                curl -s -L "$base_url"/edit_status/"$job_id"/error || true
                echo "" >&2
                return 3
            fi
            cat "$file".vmaf.json
        fi
    set -e

    rm -f \
        "$file" \
        "$file".fpf \
        "$file".vmaf.json

    return 0
}

