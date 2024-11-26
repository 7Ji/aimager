#!/bin/bash

# aimager - rootless Arch Linux and derivations image builder
# Copyright (C) 2024 Guoxin "7Ji" Pu <pugokushin@gmail.com>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA.

# code guidelines:
# variable and function names are in the format of [a-z][a-z0-9_]*[a-z]
# environment variables are in the format of AIMAGER_[A-Z0-9_]*[A-Z]
# use always [[ ]] for test conditons, no [ ], no (( ))
# subshell is not allowed

# init shell options, and log macros
aimager_init() { 
    # e: error and exit on non-zero return
    # u: error if a varaible is not defined (unbound)
    # pipefail: error if not a whole pipe is successful
    set -euo pipefail
    # log macros expansion
    local log_common_start='echo -n "['
    local log_common_end='] ${FUNCNAME}@${LINENO}: " && false'
    log_debug="${log_common_start}DEBUG${log_common_end}"
    log_info="${log_common_start}INFO${log_common_end}"
    log_warn="${log_common_start}WARN${log_common_end}"
    log_error="${log_common_start}ERROR${log_common_end}"
    log_fatal="${log_common_start}FATAL${log_common_end}"
    local log_level="${AIMAGER_LOG_LEVEL:-info}"
    case "${log_level,,}" in
    'info')
        log_debug='true'
        ;;
    'warn')
        log_debug='true'
        log_info='true'
        ;;
    'error')
        log_debug='true'
        log_info='true'
        log_warn='true'
        ;;
    'fatal')
        log_debug='true'
        log_info='true'
        log_warn='true'
        log_error='true'
        ;;
    esac
    # variables
    ## architecture
    arch_host=$(uname -m)
    arch_target="${arch_host}"
    ## built-in config options
    board='none'
    distro=''
    ## caller-defined config options
    build_id=''
    overlays=()
    initrd_maker=''
    repo_core=''
    repos_base=()
    ## repo definition option
    repo_url_parent=''
    declare -gA repo_urls
    reuse_root_tar=''
    ## run-time behaviour
    freeze_pacman_config=0
    freeze_pacman_static=0
    tmpfs_root=0
    ## run target options
    run_binfmt_check=''
}

# check if an executable exists
## $1: executable name
## $2: hint
## $3: missing callback
check_executable() {
    eval "${log_debug}" || echo "Checking executable $1"
    local type_executable
    if ! type_executable=$(type -t "$1"); then
        eval "${log_error}" || echo "Could not find needed executable \"$1\". It's needed to $2."
        "$3"
        if ! type_executable=$(type -t "$1"); then
            eval "${log_error}" || echo "Still could not find needed executable \"$1\" after callback \"$3\". It's needed to $2."
            return 1
        fi
        # explicit fallthrough: unless callback is false, we would check whether the executable becomes available after callback
    fi
    if [[ "${type_executable}" != 'file' ]]; then
        eval "${log_error}" || echo "Needed executable \"${name_executable}\" exists in Bash context but it is a \"${type_executable}\" instead of a file. It's needed to $2."
        return 1
    fi
}

# check_executable with pre-defined 'false' callback (break if non-existing)
check_executable_must_exist() {
    eval "${log_debug}" || echo "Checking executable $1 (must exist)"
    local type_executable
    if ! type_executable=$(type -t "$1"); then
        eval "${log_error}" || echo "Could not find needed executable \"$1\". It's needed to $2."
        return 1
    fi
    if [[ "${type_executable}" != 'file' ]]; then
        eval "${log_error}" || echo "Needed executable \"${name_executable}\" exists in Bash context but it is a \"${type_executable}\" instead of a file. It's needed to $2."
        return 1
    fi
}

check_executables() {
    check_executable_must_exist bsdtar 'pack root into archive'
    check_executable_must_exist curl 'download files from Internet'
    check_executable_must_exist date 'check current time'
    check_executable_must_exist id 'to check for identity'
    check_executable_must_exist install 'install file to certain paths'
    check_executable_must_exist grep 'do text extraction'
    check_executable_must_exist newgidmap 'map group to root in child namespace'
    check_executable_must_exist newuidmap 'map user to root in child namespace'
    check_executable_must_exist readlink 'get stdout psuedo terminal path'
    check_executable_must_exist sed 'do text substitution'
    check_executable_must_exist sleep 'wait for jobs to complete'
    check_executable_must_exist stat 'get file modification date'
    check_executable_must_exist tar 'extract file from archives'
    check_executable_must_exist uname 'dump machine architecture'
    check_executable_must_exist unshare 'unshare child process to do rootless stuffs'
    check_executable pacman 'install packages' update_pacman_static
    if [[ -f cache/bin/pacman && -z "${freeze_pacman:-}" ]] ; then
        update_pacman_static
    fi
    eval "${log_info}" || echo "Say hello to our hero Pacman O<. ."
    pacman --version
}

check_date_locale() {
    if [[ -z "${time_start_aimager}" ]]; then
        eval "${log_error}" || echo "Start time was not recorded, please check your 'date' installation"
        return 1
    fi
    if [[ "${LANG}$(LANG=C date -ud @0)" != 'CThu Jan  1 00:00:00 UTC 1970' ]]; then
        eval "${log_error}" || echo "Current locale was not in C or not correctly in C. The following is a date example and it's not in strict C manner: $(date)"
        return 1
    fi
}

download() { # 1: url, 2: path, 3: mod
    rm -f "$2"{,.temp}
    echo -n | install -Dm"${3:-644}" /dev/stdin "$2".temp
    eval "${log_info}" || echo "Downloading '$2' < '$1'"
    curl -qgb "" -fL --retry 3 --retry-delay 3 -o "$2".temp "$1" || return 1
    eval "${log_info}" || echo "Downloaded '$2' <= '$1'"
    mv "$2"{.temp,}
}

touched_after_start() { #1: path
    [[ $(stat -c '%Y' "$1" 2>/dev/null) -ge "${time_start_aimager}" ]]
}

get_repo_db() { #1: repo url, 2: repo name, 3: arch
    mirror_format "$1" "$2" "$3"
    db_path="cache/repo/$2:$3.db"
    touched_after_start "${db_path}" && return
    download "${mirror_formatted}/$2.db" "${db_path}"
}

get_repo_pkg() { #1: repo url, 2: repo name, 3: arch, 4: package
    get_repo_db "$1" "$2" "$3"
    pkg_ver=
    local pkg_file_remote=
    local line= pkg_name=
    for line in $(tar -xOf "${db_path}" --wildcards "$4"'-*/desc' | sed -n '/%FILENAME/{n;p;};/%NAME%/{n;p;};/%VERSION%/{n;p;}'); do
        [[ -z "${pkg_file_remote}" ]] && pkg_file_remote="${line}" && continue
        [[ -z "${pkg_name}" ]] && pkg_name="${line}" && continue
        pkg_ver="${line}"
        [[ "${pkg_name}" == "$4" ]] && break
        pkg_file_remote=
        pkg_name=
    done
    if [[ "${pkg_name}" != "$4" ]] || [[ -z "${pkg_file_remote}" ]] || [[ -z "${pkg_ver}" ]]; then
        eval "${log_error}" || echo "Failed to get package '$4' of arch '$3' from repo '$2' at '$1'"
        return 1
    fi
    eval "${log_info}" || echo "Latest '$4' of arch '$3' from repo '$2' at '$1' is at version '${pkg_ver}'"
    pkg_file_local="$2:$3:${pkg_file_remote}"
    pkg_path=cache/pkg/"${pkg_file_local}"
    if [[ -f "${pkg_path}" ]]; then
        eval "${log_info}" || echo "Skipped downloading as '${pkg_path}' already exists locally"
        return
    fi
    download "${mirror_formatted}/${pkg_file_remote}" "${pkg_path}"
}

get_repo_pkg_file() { #1: repo url, 2: repo name, 3: arch, 4: package, 5: file path
    get_repo_pkg "$1" "$2" "$3" "$4"
    pkg_dir_path="${pkg_path%.pkg.tar*}"
    mkdir -p "${pkg_dir_path}"
    tar -C "${pkg_dir_path}" -xf "cache/pkg/${pkg_file_local}" "$5"
}

update_pacman_static() {
    eval "${log_info}" || echo 'Trying to update pacman-static from archlinuxcn repo'
    if touched_after_start cache/bin/pacman; then
        eval "${log_info}" || echo 'Local pacman-static was already updated during this run, no need to update'
        return
    fi
    repo_archlinuxcn
    get_repo_pkg_file "${repo_url_archlinuxcn}" archlinuxcn "${arch_host}" pacman-static usr/bin/pacman-static
    mkdir -p cache/bin
    ln -sf "../pkg/${pkg_dir_path#cache/pkg/}/usr/bin/pacman-static" cache/bin/pacman
}

prepare_pacman_conf() {
    eval "${log_info}" || echo "Preparing pacman configs from ${distro_stylised} repo at '${repo_url_base}'"
    if [[ "${freeze_pacman}" && cache/etc/pacman-strict.conf && -f cache/etc/pacman-loose.conf ]]; then
        eval "${log_info}" || echo 'Local pacman configs exist and --freeze-pacman was set, using existing configs'
        return
    elif touched_after_start cache/etc/pacman-strict.conf &&
        touched_after_start cache/etc/pacman-loose.conf
    then
        eval "${log_info}" || echo 'Local pacman configs were already updated during this run, no need to update'
        return
    fi
    get_repo_pkg_file "${repo_url_base}" "${repo_core}" "${arch_target}" pacman etc/pacman.conf
    mkdir -p cache/etc

    local repo_base has_core=
    if (( "${#repos_base}" )); then
        for repo_base in "${repos_base[@]}"; do
            case "${repo_base}" in
            options)
                eval "${log_error}" || echo "User-defined base repo contains 'options' which is not allowed: ${repos_base[@]}"
                return 1
                ;;
            "${repo_core}")
                has_core='yes'
                ;;
            esac
        done
    else
        for repo_base in $(sed -n 's/^\[\(.\+\)\]$/\1/p' < "${pkg_dir_path}/etc/pacman.conf"); do
            case "${repo_base}" in
            options)
                continue
                ;;
            "${repo_core}")
                has_core='yes'
                ;;
            esac
            repos_base+=("${repo_base}")
        done
    fi
    if [[ -z "${has_core}" ]]; then
        eval "${log_error}" || echo "Core repo '${repo_core}' was not found in base repos: ${repos_base[@]}"
        return 1
    fi
    eval "${log_info}" || echo "Distribution ${distro_stylised} has the following base repos: ${repos_base[@]}"
    local config_head=$(
        echo '[options]'
        printf '%-13s= %s\n' \
            'RootDir' "${path_root}" \
            'DBPath' "${path_root}/var/lib/pacman/" \
            'CacheDir' 'cache/pkg/'"${distro_safe}:${arch_target}" \
            'LogFile' "${path_root}/var/log/pacman.log" \
            'GPGDir' "${path_root}/etc/pacman.d/gnupg" \
            'HookDir' "${path_root}/etc/pacman.d/hooks" \
            'Architecture' "${arch_target}"
    )
    local config_tail=$(printf '[%s]\nServer = '"${repo_url_base}"'\n' "${repos_base[@]}")
    printf '%s\n%-13s= %s\n%s' "${config_head}" 'SigLevel' 'Never' "${config_tail}" > cache/etc/pacman-loose.conf
    printf '%s\n%-13s= %s\n%s' "${config_head}" 'SigLevel' 'DatabaseOptional' "${config_tail}" > cache/etc/pacman-strict.conf
    eval "${log_info}" || echo "Generated loose config at 'cache/etc/pacman-loose.conf' and strict config at 'cache/etc/pacman-strict.conf'"
}

get_architecture() { #1
    case "${architecture}" in
        auto|host|'')
            architecture=$(uname -m)
            local allowed_architecture
            for allowed_architecture in "${allowed_architectures[@]}"; do
                [[ "${allowed_architecture}" == "${architecture}" ]] && return 0
            done
            eval "${log_error}" || echo "Auto-detected architecture '${architecture}' is not allowed for distro '${distro}'. Allowed: ${allowed_architectures[*]}"
            return 1
            ;;
        *)
            architecture="${allowed_architectures[0]}"
            ;;
    esac
}

get_distro() {
    distro=$(source /etc/os-release; echo $NAME)
    local allowed_architectures=()
    case "${distro}" in
        'Arch Linux')
            allowed_architectures=(x86_64)
            ;;
        'Arch Linux ARM')
            allowed_architectures=(aarch64 armv7h)
            ;;
        'Loong Arch Linux')
            allowed_architectures=(loong64)
            ;;
        *)
            eval "${log_warn}" || echo "Unknown distro from /etc/os-release: ${distro}"
            ;;
    esac
}

no_source() {
    eval "${log_fatal}" || echo "Both 'source' and '.' are banned from aimager, aimager is strictly single-file only"
    return 1
}
source() { no_source; }
.() { no_source; }
board_none() { :; }

board_x64_uefi() {
    distro='Arch Linux'
    arch_target='x86_64'
    bootloader='systemd-boot'
}

board_x86_legacy() {
    distro='Arch Linux 32'
    arch_target='i686'
    bootloader='syslinux'
}

board_amlogic_s9xxx() {
    distro='Arch Linux ARM'
    arch_target='aarch64'
    bootloader='u-boot'
}

_board_orangepi_5_family() {
    distro='Arch Linux ARM'
    arch_target='aarch64'
    bootloader='u-boot'
}

board_orangepi_5() {
    _board_orangepi_5_family
}

board_orangepi_5_plus() {
    _board_orangepi_5_family
}

board_orangepi_5_max() {
    _board_orangepi_5_family
}

board_orangepi_5_pro() {
    _board_orangepi_5_family
}

help_board() {
    local name prefix=board_ boards=()
    for name in $(declare -F); do
        if [[ "${name}" == "${prefix}"* && ${#name} -gt 6 ]]; then
            boards+=("${name:6}")
        fi
    done
    eval "${log_info}" || echo "Available boards: ${boards[@]}"
    return
}

# All third-party repo definitions, in alphabetical order
# Unlike distros, we do not enforce architecture detection in third-party repos, as:
#  1. These repo might be used for host (like archlinuxcn for pacman-static), checking target architecure is no good
#  2. It would be very easy to add a new architecture support to a thrid-party repo, unlike to a distro

# https://github.com/7Ji/archrepo/
repo_7Ji() {
    if [[ -z "${repo_url['7Ji']}" ]]; then
        if [[ "${repo_url_parent}" ]]; then
            repo_url['7Ji']="${repo_url_parent}"'/$repo/$arch'
        else
            repo_url['7Ji']='https://github.com/$repo/archrepo/releases/download/$arch'
        fi
    fi
    repo_keyring['7Ji']='7ji-keyring'
}

# https://arch4edu.org/
repo_arch4edu() {
    if [[ -z "${repo_url['arch4edu']}" ]]; then
        if [[ "${repo_url_parent}" ]]; then
            repo_url['arch4edu']="${repo_url_parent}"'$repo/$arch'
        else
            repo_url['arch4edu']='https://repository.arch4edu.org/$arch'
        fi
    fi
    repo_keyring['archlinuxcn']='arch4edu-keyring'
}

# https://www.archlinuxcn.org/archlinux-cn-repo-and-mirror/
repo_archlinuxcn() {
    if [[ -z "${repo_url['archlinuxcn']}" ]]; then
        if [[ "${repo_url_parent}" ]]; then
            repo_url['archlinuxcn']="${repo_url_parent}/archlinuxcn/"'$arch'
        else
            repo_url['archlinuxcn']='https://repo.archlinuxcn.org/$arch'
        fi
    fi
    repo_keyring['archlinuxcn']='archlinuxcn-keyring'
}

require_arch_target() {
    local architecture
    for architecture in "$@"; do
        if [[ "${arch_target}" == "${architecture}" ]]; then
            return
        fi
    done
    eval "${log_error}" || echo "${distro_stylised} requires target architecture to be one of $@, but it is ${arch_target}"
    return 1
}

_distro_common() {
    repo_core="${repo_core:-core}"
}

distro_archlinux() {
    distro_stylised='Arch Linux'
    distro_safe='archlinux'
    require_arch_target x86_64
    _distro_common
    if [[ -z "${repo_url['archlinux']}" ]]; then
        local mirror_arch_suffix='$repo/os/$arch'
        if [[ "${repo_url_parent}" ]]; then
            repo_url['archlinux']="${repo_url_parent}/archlinux/${mirror_arch_suffix}"
        else
            repo_url['archlinux']="https://geo.mirror.pkgbuild.com/${mirror_arch_suffix}"
        fi
    fi
    declare -gn repo_url_base=repo_url['archlinux']
}

distro_archlinux32() {
    distro_stylised='Arch Linux 32'
    distro_safe='archlinux32'
    require_arch_target i486 pentium4 i686
    _distro_common
    if [[ -z "${repo_url['archlinux32']}" ]]; then
        if [[ "${repo_url_parent}" ]]; then
            repo_url['archlinux32']="${repo_url_parent}"'/archlinux32/$arch/$repo'
        else
            eval "${log_error}" || echo 'Arch Linux 32 does not have a globally GeoIP-based mirror and a local mirror must be defined through either --repo-url-archlinux32 or --repo-url-parent. Please choose one from https://www.archlinux32.org/download or use your own local mirror.'
            return 1
        fi
    fi
    declare -gn repo_url_base=repo_url['archlinux32']
}

distro_archlinuxarm() {
    distro_stylised='Arch Linux ARM'
    distro_safe='archlinuxarm'
    require_arch_target aarch64 armv7h
    _distro_common
    if [[ -z "${repo_url['archlinuxarm']}" ]]; then
        local mirror_alarm_suffix='$arch/$repo'
        if [[ "${repo_url_parent}" ]]; then
            repo_url['archlinuxarm']="${repo_url_parent}/archlinuxarm/${mirror_alarm_suffix}"
        else
            repo_url['archlinuxarm']='http://mirror.archlinuxarm.org/'"${mirror_alarm_suffix}"
        fi
    fi
    declare -gn repo_url_base=repo_url['archlinuxarm']
}

distro_loongarchlinux() {
    distro_stylised='Loong Arch Linux'
    distro_safe='loongarchlinux'
    require_arch_target loong64
    _distro_common
    if [[ -z "${repo_url['loongarchlinux']}" ]]; then
        if [[ "${repo_url_parent}" ]]; then
            repo_url['loongarchlinux']="${repo_url_parent}"'/loongarch/archlinux/$repo/os/$arch'
        else
            eval "${log_error}" || echo 'Loong Arch Linux does not have a globally GeoIP-based mirror and a local mirror must be defined through either --repo-url-loongarchlinux or --repo-url-parent. Please choose one from https://loongarchlinux.org/pages/download or use your own local mirror.'
            return 1
        fi
    fi
    declare -gn repo_url_base=repo_url['loongarchlinux']
}

distro_archriscv() {
    distro_stylised='Arch Linux RISC-V'
    distro_safe='archriscv'
    require_arch_target riscv64
    _distro_common
    if [[ -z "${repo_url['archriscv']}" ]]; then
        if [[ "${repo_url_parent}" ]]; then
            repo_url['archriscv']="${repo_url_parent}"'/archriscv/repo/$repo'
        else
            repo_url['archriscv']='https://riscv.mirror.pkgbuild.com/repo/$repo'
        fi
    fi
    declare -gn repo_url_base=repo_url['archriscv']
}

help_distro() {
    eval "${log_info}" || echo 'Supported distro and their supported target architectures:'
    eval "${log_info}" || echo 'Arch Linux (archlinux, arch): x86_64'
    eval "${log_info}" || echo 'Arch Linux 32 (archlinux32, arch32): i486, pentium4, i686'
    eval "${log_info}" || echo 'Arch Linux ARN (archlinuxarm, archarm, alarm): armv7h, aarch64'
    eval "${log_info}" || echo 'Loong Arch Linux (loongarchlinux, loongarch): loongarch64(rewritten to loong64), loong64'
    eval "${log_info}" || echo 'Arch Linux RISC-V (archriscv, archlinuxriscv): riscv64'
    return
}

mirror_format() { #1 mirror url, #2 repo, #3 arch
    local mirror="${1/\$repo/$2}"
    mirror_formatted="${mirror/\$arch/$3}"
}

configure_environment() {
    export PATH="${PWD}/cache/bin:${PATH}" LANG=C
    time_start_aimager=$(date +%s) || time_start_aimager=''
}

configure_board() {
    local board_func="board_${board/-/_}"
    if [[ $(type -t "${board_func}") == function ]]; then
        "${board_func}"
    else
        eval "${log_error}" || echo "Board '${board}' is not supported, pass --board help to get a list of supported boards"
        return 1
    fi
}

configure_distro() {
    case "${distro}" in
    'Arch Linux'|'archlinux'|'arch')
        distro_archlinux
        ;;
    'Arch Linux 32'|'archlinux32'|'arch32')
        distro_archlinux32
        ;;
    'Arch Linux ARM'|'archlinuxarm'|'archarm'|'alarm')
        distro_archlinuxarm
        ;;
    'Loong Arch Linux'|'loongarchlinux'|'loongarch')
        distro_loongarchlinux
        ;;
    'Arch Linux RISC-V'|'archlinuxriscv'|'archriscv')
        distro_archriscv
        ;;
    *)
        eval "${log_error}" || echo "Unsupported distro '${distro}', use --disto help to check the list of supported distros"
        return 1
        ;;
    esac
}

configure_persistent() {
    configure_board
    configure_distro
}

configure_architecture() {
    if [[ "${arch_host}" == 'loongarch64' ]]; then
        arch_host='loong64'
    fi
    if [[ "${arch_target}" == 'loongarch64' ]]; then
        arch_target='loong64'
    fi
    if [[ "${arch_host}" != "${arch_target}" ]]; then
        architecture_cross='yes'
    else
        architecture_cross=''
    fi
}

configure_build_id() {
    if [[ -z "${build_id}" ]]; then
        build_id="${distro_safe}-${arch_target}-${board}"
    fi
    eval "${log_info}" || echo "Build ID is '${build_id}'"
}

configure_out() {
    if [[ -z "${out_prefix}" ]]; then
        out_prefix="out/${distro_safe}-${arch_target}-${board}-$(date +%Y%m%d%H%M%S)-"
        eval "${log_warn}" || echo "Output prefix not set, generated as '${out_prefix}'"
        if [[ "${out_prefix}" == */* ]]; then
            eval "${log_info}" || echo "Output prefix contains folder, pre-creating it..."
            mkdir -p "${out_prefix%/*}"
        fi
    fi
    out_root_tar="${out_prefix}root.tar"
}

configure_dynamic() {
    configure_architecture
    configure_build_id
    configure_out
}

configure() {
    configure_environment
    configure_persistent
    configure_dynamic
}

check() {
    check_executables
    check_date_locale
    eval "${log_info}" || echo "Aimager check complete. $(( $(date +%s) - ${time_start_aimager} )) seconds has elasped since aimager started at $(date -d @"${time_start_aimager}")"
}

binfmt_check() {
    if [[ "${arch_target}" == loong64 ]]; then
        local arch_target=loongarch64
    fi
    if [[ "${arch_host}" != "${arch_target}" ]]; then
        eval "${log_warn}" || echo "Host architecture ${arch_host} != target architecture ${arch_target}, checking if we have binfmt ready"
        eval "${log_info}" || echo "Running the following test command: 'sh -c \"cd test/binfmt; ./test.sh ${arch_target}\"'"
        sh -c 'cd test/binfmt; ./test.sh '"${arch_target}"
        pwd
    fi
}

identity_get_name_uid_gid() {
    identity_name=$(id --real --user --name)
    identity_uid=$(id --real --user)
    identity_gid=$(id --real --group)
}

identity_require_root() {
    identity_get_name_uid_gid
    if [[ "${identity_name}" != 'root' ]]; then
        eval "${log_error}" || echo  "Current context require us to run as root but we are ${identity_name}"
        return 1
    fi
    if [[ "${identity_uid}" != '0' ]]; then
        eval "${log_error}" || echo  "Current context require us to run as root (UID = 0) but we have UID ${identity_uid}"
        return 1
    fi
    if [[ "${identity_gid}" != '0' ]]; then
        eval "${log_error}" || echo  "Current context require us to run as root (GID = 0) but we have GID ${identity_uid}"
        return 1
    fi
}

identity_require_non_root() {
    identity_get_name_uid_gid
    if [[ "${identity_name}" == 'root' ]]; then
        eval "${log_error}" || echo  'Current context require us to NOT run as root but we are root'
        return 1
    fi
    if [[ "${uid}" == '0' ]]; then
        eval "${log_error}" || echo  'Current context require us to NOT run as root (UID != 0) but we have UID 0'
        return 1
    fi
    if [[ "${gid}" == '0' ]]; then
        eval "${log_error}" || echo  'Current context require us to NOT run as root (GID != 0) but we have GID 0'
        return 1
    fi
}

identity_require_mapped_root() {
    identity_require_root
    eval "${log_info}" || echo 'Trying to write content under /sys to check whether we were mapped to root or are real root'
    if echo test > /sys/sys_write_test; then
        eval "${log_error}" || echo 'We can write to /sys which means we have real root permission, refuse to continue as real root'
        return 1
    else
        eval "${log_info}" || echo 'We are not real root and were just mapped to root in child namespace, everything looks good'
    fi
}

identity_get_subid() { #1: type
    declare -n identity_id="identity_$1"
    local identity_subids=($(sed -n 's/^'"${identity_name}"':\([0-9]\+:[0-9]\+\)$/\1/p' "/etc/sub$1"))
    if [[ "${#identity_subids[@]}" == 0 ]]; then
        identity_get_subids=($(sed -n 's/^'"${identity_id}"':\([0-9]\+:[0-9]\+\)$/\1/p' "/etc/sub$1"))
        if [[ "${#identity_subids[@]}" == 0 ]]; then
            eval "${log_error}" || echo "Could not find ${1}map record for user ${identity_name} ($1 ${identity_id}) in /etc/sub$1"
            return 1
        fi
    fi
    identity_subid="${identity_subids[-1]}"
}

identity_get_subids() {
    # We need to map the user to 0:0, and others to 1:65535
    # The following function is currently not needed here as we're called at a very late time at which those were already gotten
    # but keep it in case we want to swap some logic around
    # identity_get_name_uid_gid
    identity_get_subid uid
    identity_subuid_range="${identity_subid#*:}"
    if [[ "${identity_subuid_range}" -lt 65535 ]]; then
        eval "${log_error}" || echo "Recorded subuid range in /etc/subuid too short (${identity_subuid_range} < 65535)"
        exit 1
    fi
    identity_subuid_start="${identity_subid%:*}"
    identity_get_subid gid
    identity_subgid_range="${identity_subid#*:}"
    if [[ "${identity_subgid_range}" -lt 65535 ]]; then
        eval "${log_error}" || echo "Recorded subgid range in /etc/subgid too short (${identity_subgid_range} < 65535)"
        exit 1
    fi
    identity_subgid_start="${identity_subid%:*}"
}

child_wait() {
    eval "${log_debug}" || echo "Child $$ started and waiting for parent to map us..."
    local i mapped=''
    for i in {0..10}; do
        if identity_require_mapped_root; then
            mapped='yes'
            break
        fi
        eval "${log_info}" || echo 'Waiting for parent to map us...'
        sleep 1
    done
    if [[ -z "${mapped}" ]]; then
        eval "${log_error}" || echo 'Give up after waiting for 10 seconds yet parents fail to map us'
        return 1
    fi
    eval "${log_debug}" || echo 'Child wait complete'
}

child_fs() {
    rm -rf "${path_root}"
    mkdir -p "${path_root}"/{boot,dev,etc/pacman.d,proc,run,sys,tmp,var/{cache/pacman/pkg,lib/pacman,log}}
    mount "${path_root}" "${path_root}" -o bind
    mount tmpfs-dev "${path_root}"/dev -t tmpfs -o mode=0755,nosuid
    mount tmpfs-sys "${path_root}"/sys -t tmpfs -o mode=0755,nosuid
    mkdir -p "${path_root}"/{dev/{shm,pts},sys/module}
    chmod 1777 "${path_root}"/{dev/shm,tmp}
    chmod 555 "${path_root}"/{proc,sys}
    mount proc "${path_root}"/proc -t proc -o nosuid,noexec,nodev
    mount devpts "${path_root}"/dev/pts -t devpts -o mode=0620,gid=5,nosuid,noexec
    local node
    for node in full null random tty urandom zero; do
        devnode="${path_root}"/dev/"${node}"
        touch "${devnode}"
        mount /dev/"${node}" "${devnode}" -o bind
    done
    ln -s /proc/self/fd/2 "${path_root}"/dev/stderr
    ln -s /proc/self/fd/1 "${path_root}"/dev/stdout
    ln -s /proc/self/fd/0 "${path_root}"/dev/stdin
    ln -s /proc/kcore "${path_root}"/dev/core
    ln -s /proc/self/fd "${path_root}"/dev/fd
    ln -s pts/ptmx "${path_root}"/dev/ptmx
    ln -s $(readlink -f /dev/stdout) "${path_root}"/dev/console
}

child_clean() {
    rm -rf "${path_root}"/dev/* cache/sys/*
}

child() {
    child_wait
    child_fs
    if [[ "${reuse_root_tar}" ]]; then
        eval "${log_info}" || echo "Reusing root tar ${reuse_root_tar}"
        bsdtar --acls --xattrs -xpf "${reuse_root_tar}" -C "${path_root}"
    else
        pacman -Sy --config cache/etc/pacman-loose.conf --noconfirm base
    fi
    local overlay
    for overlay in "${overlays[@]}"; do
        bsdtar --acls --xattrs -xpf "${overlay}" -C "${path_root}"
    done
    eval "${log_info}" || echo "Creating root archive to '${out_root_tar}'..."
    bsdtar --acls --xattrs -cpf "${out_root_tar}.temp" -C "${path_root}" --exclude ./dev --exclude ./proc --exclude ./sys .
    mv "${out_root_tar}"{.temp,}
    eval "${log_info}" || echo 'Child exiting!!'
}

prepare_child_context() {
    {
        echo 'set -euo pipefail'
        declare -p | grep 'declare -[-fFgIpaAilnrtux]\+ [a-z_]'
        declare -f
        echo 'child'
    } >  cache/child.sh
}

run_child_and_wait_sync() {
    eval "${log_info}" || echo 'System unshare support --map-users and --map-groups, using unshare itself to map'
    eval "${log_info}" || echo 'Spwaning child (sync)...'
    unshare --user --pid --mount --fork \
        --map-root-user \
        --map-users="${map_users}" \
        --map-groups="${map_groups}" \
        -- \
        /bin/bash cache/child.sh
}

run_child_and_wait_async() {
    eval "${log_info}" || echo 'System unshare does not support --map-users and --map-groups, mapping manually using newuidmap and newgidmap'
    eval "${log_info}" || echo 'Spwaning child (async)...'
    unshare --user --pid --mount --fork \
        /bin/bash cache/child.sh  &
    pid_child="$!"
    sleep 1
    newuidmap "${pid_child}" 0 "${identity_uid}" 1 1 "${identity_subuid_start}" "${identity_subuid_range}"
    newgidmap "${pid_child}" 0 "${identity_gid}" 1 1 "${identity_subgid_start}" "${identity_subgid_range}"
    eval "${log_info}" || echo "Mapped UIDs and GIDs for child ${pid_child}, waiting for it to finish..."
    wait "${pid_child}"
    eval "${log_info}" || echo "Child ${pid_child} finished successfully"
}

run_child_and_wait() {
    local unshare_fields=$(unshare --help | sed 's/^ \+--map-users=\(.\+\)$/\1/p' -n)
    # Just why do they change the CLI so frequently?
    case "${unshare_fields}" in
    '<inneruid>:<outeruid>:<count>') # 2.40, Arch
        local map_users="1:${identity_subuid_start}:${identity_subuid_range}"
        local map_groups="1:${identity_subgid_start}:${identity_subgid_range}"
        run_child_and_wait_sync
        ;;
    '<outeruid>,<inneruid>,<count>') # 2.38, Debian 12
        local map_users="${identity_subuid_start},1,${identity_subuid_range}"
        local map_groups="${identity_subgid_start},1,${identity_subgid_range}"
        run_child_and_wait_sync
        ;;
    *) # <= 2.37, e.g. 2.37, Ubuntu 22.04, used on Github Actions
        run_child_and_wait_async
        ;;
    esac
}

work() {
    eval "${log_info}" || echo "Building for distro '${distro}' to architecture '${arch_target}' from architecture '${arch_host}'"
    prepare_pacman_conf
    prepare_child_context
    identity_get_subids
    run_child_and_wait
}

aimager() {
    identity_require_non_root
    configure
    if  [[ "${run_binfmt_check}" ]]; then
        binfmt_check
        return
    fi
    check
    work
}

help_aimager() {
    echo 'Usage:'
    echo "  $0 ([--option] ([option argument])) ..."
    echo 'Currently under development, help message is hidden as it does not reflect the actual code'
    return
    local formatter='    --%-25s %s\n'

    printf '\nArchitecture options:\n'
    printf -- "${formatter}" \
        'arch-host [arch]' 'host architecture; default: result of `uname -m`' \
        'arch-target [arch]' 'target architecure; default: result of `uname -m`' \

    printf '\nBuilt-in config options:\n' 
    printf -- "${formatter}" \
        'board [board]' 'board, setting "help" would print a list of supported boards; default: none' \
        'distro [distro]*' 'distro, required, setting "help" would print a list of supported distros' \
    
    printf '\Image config options:\n'
    printf -- "${formatter}" \
        'build-id [build id]' 'a unique build id; default: [distro safe name]-[target architecture]-[board]-[yyyymmddhhmmss]' \
        'initrd-maker [maker]' 'initrd/initcpio/initramfs maker: mkinitcpio/booster' \
        'overlay [overlay]' 'path of overlay (a tar file), extracted to the target image after all other configuration is done, can be specified multiple-times' \
        'pkg [pkg]' 'install the specified package into the target image, can be specified multiple times, default: base' \
        'repo-core [repo]' 'the name of the distro core repo, this is used to dump etc/pacman.conf from the pacman package; default: core' \
        'repos-base [repo]' 'comma seperated list of base repos, order matters, if this is not set then it is generated from the pacman package dumped from core repo, as the upstream list might change please only set this when you really want a different list from upstream such as when you want to enable a testing repo, e.g., core-testing,core,extra-testing,extra,multilib-testing,multilib default: [none]' \

    printf '\Repo-definition options:\n'
    printf -- "${formatter}" \
        'repo-define-[name] [url]' 'define a new repo which could be referenced in later logics' \
        'repo-url-parent [parent]' 'the URL parent of repos, usually public mirror sites fast and close to the builder, used to generate the whole repo URL, if this is not set then global mirror URL would be used if that repo has defined such, some repos need always this to be set as they do not provide a global URL, note this has no effect on the pacman.conf in final image but only for building; default: [none]; e.g.: https://mirrors.mit.edu' \
        'repo-url-[name] [url]' 'specify the full URL for a certain repo, should be in the format used in pacman.conf Server= definition, if this is not set for a repo then it would fall back to --repo-url-parent logic (see above), for third-party repos the name is exactly its name and for offiical repos the name is exactly the undercased distro name (first name in bracket in --distro help), note this has no effect on the pacman.conf in final image but only for building; default: [none]; e.g.: --repo-url-archlinux '"'"'https://mirrors.xtom.com/archlinux/$repo/os/$arch/'"'" \

    printf '\nBuilder behaviour options:\n'
    printf -- "${formatter}" \
        'freeze-pacman-config' 'do not re-generate cache/etc/pacman-loose.conf and cache/etc/pacman-strict.conf from repo' \
        'freeze-pacman-static' 'for hosts that do not have system-provided pacman, do not update pacman-static online if we already downloaded it previously; this is strongly NOT recommended UNLESS you are doing continuous builds and re-using the same cache' \
        'reuse-root-tar [tar]' 'reuse a tar to skip root bootstrapping and package installation, only board-specific operation would be performed' \
    
    printf '\nRun-target options:\n'
    printf -- "${formatter}" \
        'binfmt-check' 'run a binfmt check for the target architecture after configuring and early quit' \
        'help' 'print this help message' \

}

report_wrong_arg() { # $1: prefix, $2 original args collapsed, $3: remaining args
    echo "$1 $2"
    local args_remaining_collapsed="${@:3}"
    printf "%$(( ${#1} + ${#2} - ${#args_remaining_collapsed} ))s^"
    local len="${#3}"
    while (( $len )); do
        echo -n '~'
        let len--
    done
    echo
}

aimager_cli() {
    # declare -A config_dynamic
    # declare
    local args_original="$@"
    while (( $# > 0 )); do
        case "$1" in
        # Architecture options
        '--arch-host')
            arch_host="$2"
            shift
            ;;
        '--arch-target')
            arch_target="$2"
            shift
            ;;
        # Built-in config options
        '--board')
            if [[ "$2" == 'help' ]]; then
                help_board
                return
            fi
            board="$2"
            shift
            ;;
        '--distro')
            if [[ "$2" == 'help' ]]; then
                help_distro
                return
            fi
            distro="$2"
            shift
            ;;
        # Image config options
        '--build-id')
            build_id="$2"
            shift
            ;;
        '--overlay')
            overlays+=("$2")
            shift
            ;;
        '--inird-maker')
            initrd_maker="$2"
            shift
            ;;
        '--repo-core')
            repo_core="$2"
            shift
            ;;
        '--repos-base')
            IFS=', ' read -r -a repos_base <<< "$2"
            shift
            ;;
        # Repo-definition options
        '--repo-url-parent')
            repo_url_parent="$2"
            shift
            ;;
        '--repo-url-'*)
            repo_url["${1:11}"]="$2"
            shift
            ;;
        # Run-time behaviour options
        '--freeze-pacman')
            freeze_pacman='yes'
            ;;
        '--reuse-root-tar')
            reuse_root_tar="$2"
            shift
            ;;
        '--tmpfs-root')
            tmpfs_root=1
            shift
            ;;
        # Run-target options
        '--binfmt-check')
            run_binfmt_check='yes'
            ;;
        '--help')
            help_aimager
            return 0
            ;;
        *)
            if ! eval "${log_error}"; then
                echo "Unknown argument '$1'"
                report_wrong_arg './aimager.sh' "${args_original[*]}" "$@"
            fi
            return 1
            ;;
        esac
        shift
    done
    aimager
}

aimager_init
aimager_cli "$@"
