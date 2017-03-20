#!/usr/bin/env bash
#===============================================================================
#          FILE: torproxy.sh
#
#         USAGE: ./torproxy.sh
#
#   DESCRIPTION: Entrypoint for torproxy docker container
#
#       OPTIONS: ---
#  REQUIREMENTS: ---
#          BUGS: ---
#         NOTES: ---
#        AUTHOR: David Personette (dperson@gmail.com),
#  ORGANIZATION:
#       CREATED: 09/28/2014 12:11
#      REVISION: 1.0
#===============================================================================

set -o nounset                              # Treat unset variables as an error

### bandwidth: set the BW available for relaying
# Arguments:
#   KiB/s) KiB/s of data that can be relayed
# Return: Updated configuration file
bandwidth() { local kbs="${1:-10}" file=/etc/tor/torrc
    sed -i '/^RelayBandwidth/d' $file
    echo "RelayBandwidthRate $kbs KB" >>$file
    echo "RelayBandwidthBurst $(( kbs * 2 )) KB" >>$file
}

### socks_listen_address: set the socks listen address
# Arguments:
#   IP address to listen on
# Return: Updated configuration file
socks_listen_address() { local socks_listen_addresses="$1" file=/etc/tor/torrc
    sed -i '/^SocksListenAddress/d' $file
    for socks_listen_address_or_name in $socks_listen_addresses; do
        socks_listen_ipv4_addresses="$(getent ahostsv4 ""$socks_listen_address_or_name"" | grep STREAM | cut -d' ' -f1)"
        socks_listen_ipv6_addresses="$(getent ahostsv6 ""$socks_listen_address_or_name"" | grep STREAM | cut -d' ' -f1)"
        for socks_listen_address in $socks_listen_ipv4_addresses $socks_listen_ipv6_addresses; do
            if [ -n "$socks_listen_address" ]; then
                echo "SocksListenAddress $socks_listen_address" >>$file
            fi
        done
    done
}

### outbound_bind_address: set the outbound bind address
# Arguments:
#   IP address to bind to
# Return: Updated configuration file
outbound_bind_address() { local outbound_bind_addresses="$1" file=/etc/tor/torrc
    sed -i '/^OutboundBindAddress/d' $file
    for outbound_bind_address_or_name in $outbound_bind_addresses; do
        outbound_bind_ipv4_addresses="$(getent ahostsv4 ""$outbound_bind_address_or_name"" | grep STREAM | cut -d' ' -f1)"
        outbound_bind_ipv6_addresses="$(getent ahostsv6 ""$outbound_bind_address_or_name"" | grep STREAM | cut -d' ' -f1)"
        for outbound_bind_address in $outbound_bind_ipv4_addresses $outbound_bind_ipv6_addresses; do
            if [ -n "$outbound_bind_address" ]; then
                echo "OutboundBindAddress $outbound_bind_address" >>$file
            fi
        done
    done
}

### exitnode: Allow exit traffic
# Arguments:
#   N/A)
# Return: Updated configuration file
exitnode() { local file=/etc/tor/torrc
    sed -i '/^ExitPolicy/d' $file
}

### exitnode_country: Only allow traffic to exit in a specified country
# Arguments:
#   country) country where we want to exit
# Return: Updated configuration file
exitnode_country() { local country="$1" file=/etc/tor/torrc
    sed -i '/^StrictNodes/d; /^ExitNodes/d' $file
    echo "StrictNodes 1" >>$file
    echo "ExitNodes {$country}" >>$file
}

### hidden_service: setup a hidden service
# Arguments:
#   port) port to connect to service
#   host) host:port where service is running
# Return: Updated configuration file
hidden_service() { local port="$1" host="$2" file=/etc/tor/torrc
    sed -i '/^HiddenServicePort '"$port"' /d' $file
    grep -q '^HiddenServiceDir' $file ||
        echo "HiddenServiceDir /var/lib/tor/hidden_service" >>$file
    echo "HiddenServicePort $port $host" >>$file
}

### timezone: Set the timezone for the container
# Arguments:
#   timezone) for example EST5EDT
# Return: the correct zoneinfo file will be symlinked into place
timezone() { local timezone="${1:-EST5EDT}"
    [[ -e /usr/share/zoneinfo/$timezone ]] || {
        echo "ERROR: invalid timezone specified: $timezone" >&2
        return
    }

    if [[ -w /etc/timezone && $(cat /etc/timezone) != $timezone ]]; then
        echo "$timezone" >/etc/timezone
        ln -sf /usr/share/zoneinfo/$timezone /etc/localtime
        dpkg-reconfigure -f noninteractive tzdata >/dev/null 2>&1
    fi
}

### usage: Help
# Arguments:
#   none)
# Return: Help text
usage() { local RC=${1:-0}
    echo "Usage: ${0##*/} [-opt] [command]
Options (fields in '[]' are optional, '<>' are required):
    -h          This help
    -a \"<address>\" Configure socks listen address
    -o \"<address>\" Configure outbound bind address
    -b \"\"       Configure tor relaying bandwidth in KB/s
                possible arg: \"[number]\" - # of KB/s to allow
    -e          Allow this to be an exit node for tor traffic
    -l \"<country>\" Configure tor to only use exit nodes in specified country
                required args: \"<country>\" (IE, "US" or "DE")
                <country> - country traffic should exit in
    -s \"<port>;<host:port>\" Configure tor hidden service
                required args: \"<port>;<host:port>\"
                <port> - port for .onion service to listen on
                <host:port> - destination for service request
    -t \"\"       Configure timezone
                possible arg: \"[timezone]\" - zoneinfo timezone for container

The 'command' (if provided and valid) will be run instead of torproxy
" >&2
    exit $RC
}

while getopts ":ho:a:b:el:s:t:" opt; do
    case "$opt" in
        h) usage ;;
        o) outbound_bind_address "$OPTARG" ;;
        a) socks_listen_address "$OPTARG" ;;
        b) bandwidth "$OPTARG" ;;
        e) exitnode ;;
        l) exitnode_country "$OPTARG" ;;
        s) eval hidden_service $(sed 's/^\|$/"/g; s/;/" "/g' <<< $OPTARG) ;;
        t) timezone "$OPTARG" ;;
        "?") echo "Unknown option: -$OPTARG"; usage 1 ;;
        ":") echo "No argument value for option: -$OPTARG"; usage 2 ;;
    esac
done
shift $(( OPTIND - 1 ))

[[ "${SOCKS_LISTEN_ADDRESS:-""}" ]] && socks_listen_address "$SOCKS_LISTEN_ADDRESS"
[[ "${OUTBOUND_BIND_ADDRESS:-""}" ]] && outbound_bind_address "$OUTBOUND_BIND_ADDRESS"
[[ "${BW:-""}" ]] && bandwidth "$BW"
[[ "${EXITNODE:-""}" ]] && exitnode
[[ "${LOCATION:-""}" ]] && exitnode_country "$LOCATION"
[[ "${SERVICE:-""}" ]] && eval hidden_service \
            $(sed 's/^\|$/"/g; s/;/" "/g' <<< $SERVICE)
[[ "${TZ:-""}" ]] && timezone "$TZ"
[[ "${USERID:-""}" =~ ^[0-9]+$ ]] && usermod -u $USERID -o debian-tor
[[ "${GROUPID:-""}" =~ ^[0-9]+$ ]] && groupmod -g $GROUPID -o debian-tor
for env in $(printenv | grep '^TOR_'); do
    name=$(cut -c5- <<< ${env%%=*})
    val="\"${env##*=}\""
    [[ "$val" =~ ^\"([0-9]+|false|true)\"$ ]] && val=$(sed 's|"||g' <<<$val)
    if grep -q "^$name" /etc/tor/torrc; then
        sed -i "/^$name/s| .*| $val|" /etc/tor/torrc
    else
        echo "$name $val" >>/etc/tor/torrc
    fi
done

chown -Rh debian-tor. /etc/tor /var/lib/tor /var/log/tor 2>&1 |
            grep -iv 'Read-only' || :

if [[ $# -ge 1 && -x $(which $1 2>&-) ]]; then
    exec "$@"
elif [[ $# -ge 1 ]]; then
    echo "ERROR: command not found: $1"
    exit 13
elif ps -ef | egrep -v 'grep|torproxy.sh' | grep -q tor; then
    echo "Service already running, please restart container to apply changes"
else
    [[ -e /srv/tor/hidden_service/hostname ]] && {
        echo -en "\nHidden service hostname: "
        cat /srv/tor/hidden_service/hostname; echo; }
    /usr/sbin/privoxy --user privoxy /etc/privoxy/config
    exec /usr/bin/tor
fi
