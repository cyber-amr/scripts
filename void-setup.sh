#!/bin/bash

set -euo pipefail

if [ "$EUID" -eq 0 ]; then
	echo "Error: Do not run this script as root. Run as regular user with sudo/doas access." >&2
	exit 1
fi

if [[ ! "$USER" =~ ^[a-zA-Z0-9_-]+$ ]]; then
	echo "Error: Invalid username" >&2
	exit 1
fi

install_doas=0
sync_dotfiles=0
install_gui=0
install_brave=0
install_julia=0
setup_policykit=0

usage() {
	echo "Usage: $0 [OPTIONS]"
	echo 'Options:'
	echo ' -h, --help        Display this message'
	echo " -d, --doas        Install doas"
	echo " -s, --sync        Sync dotfiles"
	echo " -g, --gui         Install GUI (includes lightdm, compositor, and nvidia drivers)"
	echo " -b, --brave       Install Brave browser"
	echo " -j, --julia       Install Julia Programming Language"
	echo " -p, --policykit   Setup PolicyKit"
}

parse_combined_options() {
	local opts="$1"
	opts="${opts#-}" # Remove the leading dash

	for ((i=0; i<${#opts}; i++)); do
		case "${opts:$i:1}" in
			d) install_doas=1 ;;
			s) sync_dotfiles=1 ;;
			g) install_gui=1 ;;
			b) install_brave=1 ;;
			j) install_julia=1 ;;
			p) setup_policykit=1 ;;
			h) usage; exit 0 ;;
			*) echo "Invalid option: -${opts:$i:1}" >&2; usage; exit 1 ;;
		esac
	done
}

while [ $# -gt 0 ]; do
	case $1 in
		-h | --help)
			usage
			exit 0
			;;
		-d | --doas)
			install_doas=1
			;;
		-s | --sync)
			sync_dotfiles=1
			;;
		-g | --gui)
			install_gui=1
			;;
		-b | --brave)
			install_brave=1
			;;
		-j | --julia)
			install_julia=1
			;;
		-p | --policykit)
			setup_policykit=1
			;;
		-*)
			if [[ "$1" =~ ^-[dsgjp]+$ ]]; then
				parse_combined_options "$1"
			else
				echo "Invalid argument: $1" >&2
				usage
				exit 1
			fi
			;;
		*)
			echo "Invalid argument: $1" >&2
			usage
			exit 1
			;;
	esac
	shift
done

if command -v doas &> /dev/null; then
	doas="doas"
else
	doas="sudo"
fi

has_nvidia_gpu() {
	command -v lspci &> /dev/null && lspci | grep -i nvidia &> /dev/null
}

# insert <path> <quary> <line>
insert() {
	if ! grep -q $2 $1; then
		if grep -q "^#!" $1; then
			sed -i "/^#!/a $3" $1
		else
			sed -i "1i $3" $1
		fi
	fi
}

echo "Updating system..."

$doas xbps-install -Suy xbps
$doas xbps-install -y void-repo-nonfree
$doas xbps-install -Suy

# essential packages that i use
$doas xbps-install -y git patch wget curl vim yt-dlp tree

if [ $install_doas -eq 1 ]; then
	echo "Installing and configuring doas..."

	$doas xbps-install -y opendoas
	$doas bash -c "echo 'permit nopass $USER as root' > /etc/doas.conf"
	doas="doas"
fi

if [ $setup_policykit -eq 1 ]; then
	echo "Setting up PolicyKit..."

	$doas xbps-install -y polkit polkit-elogind elogind

	if [ ! -L /var/service/dbus ]; then
		$doas ln -s /etc/sv/dbus /var/service/
	fi

	if [ ! -L /var/service/elogind ]; then
		$doas ln -s /etc/sv/elogind /var/service/
	fi

	if [ ! -L /var/service/polkitd ]; then
		$doas ln -s /etc/sv/polkitd /var/service/
	fi

	$doas usermod -aG wheel "$USER"
fi

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT
cd "$TEMP_DIR"

if [ $sync_dotfiles -eq 1 ]; then
	echo "Syncing dotfiles..."

	$doas xbps-install -y rsync
	git clone --depth 1 https://github.com/cyber-amr/dotfiles.git
	rsync -a --exclude='.git/' --exclude='LICENSE' --exclude='.gitignore' dotfiles/ $HOME
fi

if [ $install_gui -eq 1 ]; then
	echo "Installing GUI components..."

	$doas xbps-install -y make gcc libX11-devel libXft-devel libXinerama-devel xorg-server xinit xauth xorg-fonts xorg-input-drivers pkg-config

	git clone --depth 1 https://github.com/cyber-amr/dwm.git
	git clone --depth 1 https://github.com/cyber-amr/dmenu.git
	git clone --depth 1 https://github.com/cyber-amr/st.git

	$doas make clean install -C ./dwm
	$doas make clean install -C ./dmenu
	$doas make clean install -C ./st

	if ! grep -q 'exec dwm' $HOME/.xinitrc 2>/dev/null; then
		echo 'exec dwm' >> $HOME/.xinitrc
	fi

	if ! grep -q 'exec startx' $HOME/.bash_profile 2>/dev/null; then
		cat <<'EOL' >> $HOME/.bash_profile

if [ "$(tty)" = "/dev/tty1" ]; then
	exec startx
fi

EOL
	fi

	echo "Setting up compositor..."

	$doas xbps-install -y xcompmgr

	insert $HOME/.xinitrc xcompmgr 'xcompmgr -c &'

	echoo "Loading background..."

	if [ ! -e "$HOME/wallpaper" ]; then
		curl https://amr-dev.info/assets/wallpaper -o $HOME/wallpaper
	fi

	insert $HOME/.xinitrc feh 'feh --no-fehbg --bg-fill $HOME/wallpaper'

	echo "Setting up layouts (us, ara, ru)..."

	$doas xbps-install -y setxkbmap

	insert $HOME/.xinitrc setxkbmap 'setxkbmap -layout us,ara,ru -option grp:win_space_toggle'

	echo "Applying mod key remaps..."

	$doas xbps-install -y xmodmap

	[ -e $HOME/.Xmodmap ] || curl https://amr-dev.info/dotfiles/.Xmodmap -o $HOME/.Xmodmap

	insert $HOME/.xinitrc xmodmap 'xmodmap $HOME/.Xmodmap'

	# intel iGPU drivers
	$doas xbps-install -y mesa-dri intel-video-accel vulkan-loader mesa-vulkan-intel

	if has_nvidia_gpu; then
		echo "NVIDIA GPU detected. Installing NVIDIA drivers..."
		$doas xbps-install -y nvidia nvidia-libs-32bit

		# Add nvidia modules to be loaded at boot
		if ! grep -q "nvidia" /etc/modules-load.d/nvidia.conf 2>/dev/null; then
			$doas mkdir -p /etc/modules-load.d
			$doas sh -c 'printf "nvidia\nnvidia_modeset\nnvidia_uvm\nnvidia_drm\n" > /etc/modules-load.d/nvidia.conf'
		fi

		# Configure Xorg for NVIDIA
		$doas nvidia-xconfig

		# Add nvidia settings to xinitrc
		insert $HOME/.xinitrc 'nvidia-settings' 'nvidia-settings --load-config-only &'

		echo "NVIDIA drivers installed. Reboot required for full functionality."
	else
		echo "No NVIDIA GPU detected. Skipping NVIDIA driver installation."
	fi

	# make sure the cache is accessible
	$doas chown -R $USER:$USER $HOME/.cache/

	# packages i use that depends on gui
	$doas xbps-install -y vscode godot
fi

if [ $install_brave -eq 1 ]; then
	bash <(curl -s https://raw.githubusercontent.com/cyber-amr/scripts/refs/heads/main/void-brave-install.sh)
fi

if [ $install_julia -eq 1 ]; then
	echo "Installing Julia..."
	$doas xbps-install -y juliaup

	if [ ! -e /usr/bin/julia ]; then
		$doas ln -s /usr/bin/julialauncher /usr/bin/julia
	fi

	juliaup self update
	juliaup add 1.0.0
	juliaup add alpha
	juliaup add 1
	juliaup default 1
fi

echo "Setup complete!"

if [ $install_gui -eq 1 ] && has_nvidia_gpu; then
	echo "Note: NVIDIA drivers were installed. Please reboot for full functionality."
fi
