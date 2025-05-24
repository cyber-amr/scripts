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
install_julia=0
setup_policykit=0

usage() {
	echo "Usage: $0 [OPTIONS]"
	echo 'Options:'
	echo ' -h, --help        Display this message'
	echo " -d, --doas        Install doas"
	echo " -s, --sync        Sync dotfiles"
	echo " -g, --gui         Install GUI (includes lightdm, compositor, and nvidia drivers)"
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

	$doas xbps-install -y polkit polkit-elogind

	if [ ! -L /var/service/elogind ]; then
		$doas ln -s /etc/sv/elogind /var/service/
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

	echo 'exec dwm' > $HOME/.xinitrc

	echo "Setting up lightdm..."

	$doas sed -i 's/^#greeter-session=.*/greeter-session=lightdm-gtk3-greeter/' /etc/lightdm/lightdm.conf
	$doas sed -i 's/^#user-session=.*/user-session=dwm/' /etc/lightdm/lightdm.conf

	$doas mkdir -p /usr/share/xsessions/
	$doas tee /usr/share/xsessions/dwm.desktop > /dev/null <<EOF
[Desktop Entry]
Name=dwm
Comment=Dynamic window manager
Exec=dwm
TryExec=dwm
Icon=
Type=Application
EOF

	$doas ln -s /etc/sv/lightdm /var/service/

	echo "Setting up compositor..."

	$doas xbps-install -y picom

	mkdir -p $HOME/.config/picom

	tee $HOME/.config/picom/picom.conf > /dev/null <<EOF
backend = "glx";
vsync = true;
detect-rounded-corners = true;
detect-client-opacity = true;
refresh-rate = 0;
detect-transient = true;
detect-client-leader = true;
use-damage = true;

# Opacity
inactive-opacity = 0.9;
active-opacity = 1.0;
frame-opacity = 1.0;
inactive-opacity-override = false;

# Fading
fading = true;
fade-delta = 4;
fade-in-step = 0.03;
fade-out-step = 0.03;

# Shadow
shadow = true;
shadow-radius = 12;
shadow-offset-x = -15;
shadow-offset-y = -15;
shadow-opacity = 0.75;
EOF

	# Add picom to xinitrc
	if ! grep -q "picom" $HOME/.xinitrc; then
		sed -i '1i picom -b &' $HOME/.xinitrc
	fi

	# intel iGPU drivers 
	$doas xbps-install -y mesa-dri intel-video-accel vulkan-loader mesa-vulkan-intel

	if has_nvidia_gpu; then
		echo "NVIDIA GPU detected. Installing NVIDIA drivers..."
		$doas xbps-install -y nvidia nvidia-libs-32bit
		
		# Add nvidia modules to be loaded at boot
		if ! grep -q "nvidia" /etc/modules-load.d/nvidia.conf 2>/dev/null; then
			$doas mkdir -p /etc/modules-load.d
			$doas tee /etc/modules-load.d/nvidia.conf > /dev/null <<EOF
nvidia
nvidia_modeset
nvidia_uvm
nvidia_drm
EOF
		fi
		
		# Configure Xorg for NVIDIA
		$doas nvidia-xconfig
		
		# Add nvidia settings to xinitrc
		if ! grep -q "nvidia-settings" $HOME/.xinitrc; then
			sed -i '1i nvidia-settings --load-config-only &' $HOME/.xinitrc
		fi
		
		echo "NVIDIA drivers installed. Reboot required for full functionality."
	else
		echo "No NVIDIA GPU detected. Skipping NVIDIA driver installation."
	fi

	# packages i use that depends on gui
	$doas xbps-install -y firefox vscode godot
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
