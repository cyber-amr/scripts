#!/bin/bash

case "$(printf "kill\nreboot\npoweroff" | dmenu -b -i)" in
	kill) ps -u $USER -o pid,comm,%cpu,%mem | dmenu -b -i -l 15 -p 'Kill:' | awk '{print $1}' | xargs -r kill ;;
	reboot) doas reboot -i ;;
	poweroff) doas poweroff ;;
	*) exit 1 ;;
esac
