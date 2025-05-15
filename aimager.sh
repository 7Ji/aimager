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
# use either [[ ]] or (( )) for test conditons, prefer (( )) over [[ ]] for math
# indent is 4 spaces
# wrap lines at 80 columns, unless the line ends with a long url

log_inner() {
    if [[ "${log_enabled[$1]}" ]]; then
        echo "[${BASH_SOURCE##*/}:${1^^}] ${FUNCNAME[2]}@${BASH_LINENO[1]}: ${*:2}"
    fi
}

log_debug() {
    log_inner debug "$@"
}

log_info() {
    log_inner info "$@"
}

log_warn() {
    log_inner warn "$@"
}

log_error() {
    log_inner error "$@"
}

log_fatal() {
    log_inner fatal "$@"
}

# init shell options, and log macros
aimager_init() { 
    # e: error and exit on non-zero return
    # u: error if a varaible is not defined (unbound)
    # pipefail: error if not a whole pipe is successful
    set -euo pipefail
    # log macros expansion
    declare -gA log_enabled=(
        [debug]='y'
        [info]='y'
        [warn]='y'
        [error]='y'
        [fatal]='y'
    )
    local AIMAGER_LOG_LEVEL="${AIMAGER_LOG_LEVEL:-info}"
    case "${AIMAGER_LOG_LEVEL,,}" in
    'debug')
        :
        ;;
    'info')
        log_enabled[debug]=''
        ;;
    'warn')
        log_enabled[debug]=''
        log_enabled[info]=''
        ;;
    'error')
        log_enabled[debug]=''
        log_enabled[info]=''
        log_enabled[warn]=''
        ;;
    'fatal')
        log_enabled[debug]=''
        log_enabled[info]=''
        log_enabled[warn]=''
        log_enabled[error]=''
        ;;
    *)
        log_fatal "Unknown log level ${AIMAGER_LOG_LEVEL}, shall be one of the"\
            "following (case-insensitive): debug, info, warn, error, fatal"
        return 1
        ;;
    esac
    # variables
    arch_host=$(uname -m)
    arch_target="${arch_host}"
    async_child=0
    board='none'
    keyring_helper=''
    build_id=''
    bootstrap_pkgs=()
    creates=()
    distro=''
    freeze_pacman_config=0
    freeze_pacman_static=0
    initrd_maker=''
    kernels=()
    declare -gA ucodes
    bootloaders=()
    bootloader_pkgs=()
    declare -gA appends
    install_pkgs=()
    hostname_original=''
    locales=()
    declare -gA mkfs_args
    out_prefix=''
    overlays=()
    pacman_conf_append=''
    repo_core=''
    repo_url_parent=''
    declare -gA repo_urls
    add_repos=()
    repos_base=()
    reuse_root_tar=''
    run_binfmt_check=0
    run_only_prepare_child=0
    run_clean_builds=0
    run_only_backup_keyring=0
    table=''
    tmpfs_root_options=''
    use_pacman_static=0
}

# check_executable $1 to $2, fail if it do not exist
check_executable() {
    log_debug "Checking executable $1 (must exist)"
    local type_executable
    if ! type_executable=$(type -t "$1"); then
        log_error \
            "Could not find needed executable \"$1\"."\
            "It's needed to $2."\
            "Refuse to continue."
        return 1
    fi
    if [[ "${type_executable}" != 'file' ]]; then
        log_error \
            "Needed executable \"${name_executable}\" exists in Bash context"\
            "but it is a \"${type_executable}\" instead of a file."\
            "It's needed to $2."\
            "Refuse to continue"
        return 1
    fi
}

check_executables() {
    check_executable bsdtar 'pack root into archive'
    check_executable curl 'download files from Internet'
    check_executable date 'check current time'
    check_executable dd 'disk image manuplication'
    check_executable id 'to check for identity'
    check_executable install 'install file to certain paths'
    check_executable grep 'do text extraction'
    check_executable mcopy 'pre-populating fat fs'
    check_executable md5sum 'simple hashing'
    check_executable mkfs.fat 'creating FAT fs'
    check_executable newgidmap 'map group to root in child namespace'
    check_executable newuidmap 'map user to root in child namespace'
    check_executable readlink 'get stdout psuedo terminal path'
    check_executable sed 'do text substitution'
    check_executable sleep 'wait for jobs to complete'
    check_executable sort 'sort values'
    check_executable stat 'get file modification date'
    check_executable tar 'extract file from archives'
    check_executable uname 'dump machine architecture'
    check_executable uniq 'get unique values'
    check_executable unshare 'unshare child process'
    check_executable uuidgen 'generate partition ids'
    if (( "${use_pacman_static}" )) ||
        ! check_executable pacman 'install packages'
    then
        use_pacman_static=1
        update_and_use_pacman_static
    fi
    log_info "Say hello to our hero Pacman O<. ."
    pacman --version
}

check_date_locale() {
    if [[ -z "${time_start_aimager}" ]]; then
        log_error \
            "Start time was not recorded, please check your 'date' installation"
        return 1
    fi
    local actual_output="${LANG}$(LANG=C date -ud @0)"
    local expected_output='CThu Jan  1 00:00:00 UTC 1970'
    if [[ "${actual_output}" != "${expected_output}" ]]; then
        log_error \
            "Current locale was not in C or not correctly in C."\
            "Was expecting output of date command to be \"${expected_output}\""\
            "But it is actually \"${actual_output}\""
        return 1
    fi
}

# download a url to a path, with specific permission mod. this would always
# delete the target file (and possibly its corresponding .temp cache file, if 
# that exists).
download() { # 1: url, 2: path, 3: mod
    rm -f "$2"{,.temp}
    echo -n | install -Dm"${3:-644}" /dev/stdin "$2".temp
    log_info "Downloading '$2' < '$1'"
    curl -qgb "" -fL --retry 3 --retry-delay 3 -o "$2".temp "$1"
    log_info "Downloaded '$2' <= '$1'"
    mv "$2"{.temp,}
}

# check if the fs entry pointed by a path ($1) was touched after aimager was 
# started, or more specifically, after configure->configure_environment was 
# called and ${time_start_aimager} was set.
# this is mostly useful to avoid updating a stuff multiple times during the same
# run of aimager.
touched_after_start() { #1: path
    local time_touched
    time_touched=$(stat -c '%Y' "$1" 2>/dev/null) || time_touched=0
    (( "${time_touched}" >= "${time_start_aimager}" ))
}

# cache a repo's db lazily, if it was already cached during this run then it
# would not be re-cached
# SET: db_path
# SET: mirror_formatted @mirror_format
cache_repo_db() { #1: repo url, 2: repo prefix, 2: repo name, 4: arch
    mirror_format "$1" "$3" "$4"
    db_path="cache/repo/$2$3:$4.db"
    if touched_after_start "${db_path}"; then
        return
    fi
    download "${mirror_formatted}/$3.db" "${db_path}"
}

# cache a pkg from a repo lazily, if it already exists locally then it would not
# be re-cached (note this is different from db)
# SET: db_path @cache_repo_db
# SET: mirror_formatted @cache_repo_db
# SET: pkg_filename
# SET: pkg_path
# SET: pkg_ver
#1: repo url, 2: repo prefix, 3: repo name, 4: arch, 5: package
cache_repo_pkg() {
    cache_repo_db "${@:1:4}"
    local cache_names_versions=$(
        tar -xOf "${db_path}" --wildcards "$5"'-*/desc' |
        sed -n '/%FILENAME/{n;p;};/%NAME%/{n;p;};/%VERSION%/{n;p;}'
    )
    local filenames=($(sed -n 'p;n;n' <<< "${cache_names_versions}"))
    local names=($(sed -n 'n;p;n' <<< "${cache_names_versions}"))
    local versions=($(sed -n 'n;n;p' <<< "${cache_names_versions}"))
    if (( ${#filenames[@]} == ${#names[@]} )) && 
        (( ${#names[@]} == ${#versions[@]} )); then
        :
    else
        log_error \
            "Dumped filenames (${#filenames[@]}), names (${#names[@]}) and"\
            "versions (${#versions[@]}) length not equal to each other"
        log_debug \
            "Dumped filesnames: ${filesnames[*]};"\
            "Dumped names: ${names[*]};"\
            "Dumped versions: ${versions[*]}"
        return 1
    fi
    pkg_ver=
    local filename= name= i=0
    for i in "${!names[@]}"; do
        name="${names[$i]}"
        if [[ "${name}" == "$5" ]]; then
            filename="${filenames[$i]}"
            pkg_ver="${versions[$i]}"
            break
        fi
    done
    if [[ "${name}" == "$5" ]] && 
        [[ "${filename}" ]] && 
        [[ "${pkg_ver}" ]]
    then
        :
    else
        log_error \
            "Failed to get package '$5' of arch '$4' from repo '$2$3' at '$1'"
        return 1
    fi
    log_info \
        "Latest '$5' of arch '$4' from repo '$2$3' at '$1'"\
        "is at version '${pkg_ver}'"
    pkg_filename="$2$3:$4:${filename}"
    pkg_path=cache/pkg/"${pkg_filename}"
    if [[ -f "${pkg_path}" ]]; then
        log_info \
            "Skipped downloading as '${pkg_path}' already exists locally"
        return
    fi
    download "${mirror_formatted}/${filename}" "${pkg_path}"
}

# cache a file from a pkg from a remote, this always re-extract the file even if
# it already exists locally
# SET: db_path @cache_repo_pkg
# SET: mirror_formatted @cache_repo_pkg
# SET: pkg_dir
# SET: pkg_filename @cache_repo_pkg
# SET: pkg_path @cache_repo_pkg
# SET: pkg_ver @cache_repo_pkg
# 1: repo url, 2: repo prefix, 3: repo name, 4: arch, 5: package, 6: path in pkg
cache_repo_pkg_file() { 
    cache_repo_pkg "${@:1:5}"
    pkg_dir="${pkg_path%.pkg.tar*}"
    mkdir -p "${pkg_dir}"
    tar -C "${pkg_dir}" -xf "cache/pkg/${pkg_filename}" "$6"
}

update_pacman_static() {
    log_info \
        'Trying to update pacman-static from archlinuxcn repo'
    if touched_after_start cache/bin/pacman-static; then
        log_info \
            'Local pacman-static was already updated during this run,'\
            'no need to update'
        return
    fi
    repo_archlinuxcn_url_only
    cache_repo_pkg_file "${repo_urls['archlinuxcn']}" '' archlinuxcn \
        "${arch_host}" pacman-static usr/bin/pacman-static
}

update_and_use_pacman_static() {
    update_pacman_static
    path_pacman_static="${pkg_dir}/usr/bin/pacman-static"
    pacman() {
        "${path_pacman_static}" "$@"
    }
}

prepare_pacman_conf() {
    log_info \
        "Preparing pacman configs from ${distro_stylised} repo"\
        "at '${repo_url_base}'"
    if (( "${freeze_pacman_config}" )) && [[ 
        -f "${path_etc}/pacman-strict.conf" && 
        -f "${path_etc}/pacman-loose.conf" ]]
    then
        log_info \
            'Local pacman configs exist and --freeze-pacman was set'\
            'using existing configs'
        return
    elif touched_after_start "${path_etc}/pacman-strict.conf" &&
        touched_after_start "${path_etc}/pacman-loose.conf"
    then
        log_info \
            'Local pacman configs were already updated during this run,'\
            'no need to update'
        return
    fi
    cache_repo_pkg_file "${repo_url_base}" "${distro_safe}:" "${repo_core}" \
        "${arch_target}" pacman etc/pacman.conf
    mkdir -p "${path_etc}"

    local repo_base has_core=
    if (( "${#repos_base[@]}" )); then
        for repo_base in "${repos_base[@]}"; do
            case "${repo_base}" in
            options)
                log_error \
                    "User-defined base repo contains 'options' which is not"\
                    "allowed: ${repos_base[*]}"
                return 1
                ;;
            "${repo_core}")
                has_core='yes'
                ;;
            esac
        done
    else
        for repo_base in $(
            sed -n 's/^\[\(.\+\)\]$/\1/p' < "${pkg_dir}/etc/pacman.conf"
        ); do
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
        log_error \
            "Core repo '${repo_core}' was not found in base repos:"\
            "${repos_base[*]}"
        return 1
    fi
    log_info \
        "Distribution ${distro_stylised} has the following base repos:"\
        "${repos_base[*]}"
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
    local config_tail=$(
        printf '[%s]\nServer = '"${repo_url_base}"'\n' "${repos_base[@]}"
        local repo
        for repo in "${add_repos[@]}"; do
            printf '[%s]\nServer = %s\n' "${repo}" "${repo_urls["${repo}"]}"
        done
    )
    printf '%s\n%-13s= %s\n%s' \
        "${config_head}" 'SigLevel' 'Never' "${config_tail}" \
        > "${path_etc}/pacman-loose.conf"
    printf '%s\n%-13s= %s\n%s' \
        "${config_head}" 'SigLevel' 'DatabaseOptional' "${config_tail}" \
        > "${path_etc}/pacman-strict.conf"
    log_info \
        "Generated loose config at '${path_etc}/pacman-loose.conf' and "\
        "strict config at '${path_etc}/pacman-strict.conf'"
}

no_source() {
    log_fatal \
        "Both 'source' and '.' are banned from aimager,"\
        "aimager is strictly single-file only"
    return 1
}
source() { no_source; }
.() { no_source; }
board_none() { :; }

table_gpt_header() {
    printf '%s:%s\n' \
        label gpt \
        sector-size 512 \

}

table_dos_header() {
    printf '%s:%s\n' \
        label dos \
        sector-size 512 \

}

table_part() { #1 name, 2 start, 3 size, 4 type, 5 suffix
    echo -n "aimager@$1:" # for dos this does nothing, but we use it for marks
    if [[ "$2" ]]; then
        echo -n "start=$2,"
    fi
    echo "size=$3,type=$4$5"
}

table_common_dos_1g_esp() {
    table_dos_header
    table_part boot '' 1G uefi ',bootable'
}

table_common_gpt_1g_esp() {
    table_gpt_header
    table_part boot '' 1G uefi ''
}

table_common_gpt_1g_esp_16g_root_aarch64() {
    table_common_gpt_1g_esp
    table_part root '' 16G '"Linux root (ARM-64)"' ''
}

table_common_gpt_1g_esp_16g_root_x86_64() {
    table_common_gpt_1g_esp
    table_part root '' 16G '"Linux root (x86-64)"' ''
}

table_common_dos_1g_esp_16g_root() {
    table_common_dos_1g_esp
    table_part root '' 16G linux ''
}

help_table() {
    local name prefix=table_common_ tables=()
    for name in $(declare -F); do
        if [[ "${name}" == "${prefix}"* && ${#name} -gt 13 ]]; then
            tables+=("=${name:13}")
        fi
    done
    log_info "Available common tables: ${tables[@]}"
    return
}

use_arch_x64() {
    distro='Arch Linux'
    arch_target='x86_64'
}

use_arch32_i686() {
    distro='Arch Linux 32'
    arch_target='i686'
}

use_alarm_aarch64() {
    distro='Arch Linux ARM'
    arch_target='aarch64'
}

use_linux_and_lts() {
    kernels+=('linux' 'linux-lts')
}

use_linux_aarch64_7ji() {
    add_repos+=('7Ji')
    kernels+=('linux-aarch64-7ji')
}

use_ucodes() {
    ucodes+=(
        [amd-ucode]='amd-ucode.img'
        [intel-ucode]='intel-ucode.img'
    )
}

use_booster() {
    initrd_maker="${initrd_maker:-booster}"
}

use_systemd_boot() {
    bootloaders+=('systemd-boot')
}

use_syslinux() {
    bootloaders+=('syslinux')
    bootloader_pkgs+=('syslinux' 'mtools')
}

use_u_boot() {
    bootloaders+=('u-boot')
}

board_x64_uefi() {
    use_arch_x64
    use_linux_and_lts
    use_ucodes
    table="${table:-=gpt_1g_esp_16g_root_x86_64}"
    use_booster
    use_systemd_boot
}

board_x64_legacy() {
    use_arch_x64
    use_linux_and_lts
    use_ucodes
    table="${table:-=dos_1g_esp_16g_root}"
    use_booster
    use_syslinux
}

board_x86_legacy() {
    use_arch32_i686
    use_linux_and_lts
    use_ucodes
    table="${table:-=dos_1g_esp_16g_root}"
    use_booster
    use_syslinux
}

board_aarch64_uefi() {
    use_alarm_aarch64
    use_linux_aarch64_7ji
    table="${table:-=gpt_1g_esp_16g_root_aarch64}"
    use_booster
    use_systemd_boot
}

board_aarch64_uboot() {
    use_alarm_aarch64
    use_linux_aarch64_7ji
    table="${table:-=gpt_1g_esp_16g_root_aarch64}"
    use_booster
    use_u_boot
}

board_amlogic_s9xxx() {
    use_alarm_aarch64
    use_linux_aarch64_7ji
    table="${table:-=dos_1g_esp_16g_root}"
    fdt='amlogic/PLEASE_SET_ME.dtb'
    use_booster
    use_u_boot
}

help_board() {
    local name prefix=board_ boards=()
    for name in $(declare -F); do
        if [[ "${name}" == "${prefix}"* && ${#name} -gt 6 ]]; then
            boards+=("${name:6}")
        fi
    done
    log_info "Available boards: ${boards[@]}"
    return
}

pacman_conf_append_repo_with_mirrorlist() { #1 repo, 2 mirrorlist name
    printf '\n[%s]\nInclude = /etc/pacman.d/%s\n' "$1" "$2"
}

# All third-party repo definitions, in alphabetical order

# https://github.com/7Ji/archrepo/
repo_7Ji() {
    require_arch_target 'Repo 7Ji' aarch64 x86_64
    local url_public='https://github.com/$repo/archrepo/releases/download/$arch'
    if [[ -z "${repo_urls['7Ji']:-}" ]]; then
        if [[ "${repo_url_parent}" ]]; then
            repo_urls['7Ji']="${repo_url_parent}"'/$repo/$arch'
        else
            repo_urls['7Ji']="${url_public}"
        fi
    fi
    bootstrap_pkgs+=('7ji-keyring')
    pacman_conf_append+=$(printf '\n[%s]\nServer = %s\n' 7Ji "${url_public}")
}

# https://arch4edu.org/
repo_arch4edu() {
    require_arch_target 'Repo arch4edu' aarch64 x86_64
    if [[ -z "${repo_urls['arch4edu']:-}" ]]; then
        if [[ "${repo_url_parent}" ]]; then
            repo_urls['arch4edu']="${repo_url_parent}"'/$repo/$arch'
        else
            repo_urls['arch4edu']='https://repository.arch4edu.org/$arch'
        fi
    fi
    bootstrap_pkgs+=('arch4edu-keyring')
    install_pkgs+=('mirrorlist.arch4edu')
    pacman_conf_append+=$(pacman_conf_append_repo_with_mirrorlist \
        'arch4edu' 'mirrorlist.arch4edu')
}

repo_archlinuxcn_url_only() {
    if [[ -z "${repo_urls['archlinuxcn']:-}" ]]; then
        if [[ "${repo_url_parent}" ]]; then
            repo_urls['archlinuxcn']="${repo_url_parent}"'/$repo/$arch'
        else
            repo_urls['archlinuxcn']='https://repo.archlinuxcn.org/$arch'
        fi
    fi
}

# https://www.archlinuxcn.org/archlinux-cn-repo-and-mirror/
repo_archlinuxcn() {
    require_arch_target 'Repo archlinuxcn' aarch64 x86_64
    repo_archlinuxcn_url_only
    bootstrap_pkgs+=('archlinuxcn-keyring')
    install_pkgs+=('archlinuxcn-mirrorlist-git')
    pacman_conf_append+=$(pacman_conf_append_repo_with_mirrorlist \
        'archlinuxcn' 'archlinuxcn-mirrorlist')
}

help_repo() {
    local name prefix=repo_ repos=()
    for name in $(declare -F); do
        if [[ "${name}" == "${prefix}"* && ${#name} -gt 5 ]]; then
            repos+=("${name:5}")
        fi
    done
    log_info "Available repos: ${repos[@]}"
    return
}

require_arch_target() { #1: who
    local architecture
    for architecture in "${@:2}"; do
        if [[ "${arch_target}" == "${architecture}" ]]; then
            return
        fi
    done
    log_error \
        "1 requires target architecture to be one of ${*:2},"\
        "but it is ${arch_target}"
    return 1
}

distro_common() {
    repo_core="${repo_core:-core}"
    bootstrap_pkgs+=('base')
}

distro_archlinux() {
    distro_stylised='Arch Linux'
    distro_safe='archlinux'
    require_arch_target "${distro_stylised}" x86_64
    distro_common
    if [[ -z "${repo_urls['archlinux']:-}" ]]; then
        local mirror_arch_suffix='$repo/os/$arch'
        if [[ "${repo_url_parent}" ]]; then
            repo_urls['archlinux']="${repo_url_parent}/archlinux/${mirror_arch_suffix}"
        else
            repo_urls['archlinux']="https://geo.mirror.pkgbuild.com/${mirror_arch_suffix}"
        fi
    fi
    declare -gn repo_url_base=repo_urls['archlinux']
}

distro_archlinux32() {
    distro_stylised='Arch Linux 32'
    distro_safe='archlinux32'
    require_arch_target "${distro_stylised}" i486 pentium4 i686
    distro_common
    if [[ -z "${repo_urls['archlinux32']:-}" ]]; then
        if [[ "${repo_url_parent}" ]]; then
            repo_urls['archlinux32']="${repo_url_parent}"'/archlinux32/$arch/$repo'
        else
            log_error \
                'Arch Linux 32 does not have a globally GeoIP-based mirror and'\
                'a local mirror must be defined through either'\
                '--repo-url-archlinux32 or --repo-url-parent.'\
                'Please choose one from https://www.archlinux32.org/download'\
                'or use your own local mirror.'
            return 1
        fi
    fi
    declare -gn repo_url_base=repo_urls['archlinux32']
}

distro_archlinuxarm() {
    distro_stylised='Arch Linux ARM'
    distro_safe='archlinuxarm'
    require_arch_target "${distro_stylised}" aarch64 armv7h
    distro_common
    if [[ -z "${repo_urls['archlinuxarm']:-}" ]]; then
        local mirror_alarm_suffix='$arch/$repo'
        if [[ "${repo_url_parent}" ]]; then
            repo_urls['archlinuxarm']="${repo_url_parent}/archlinuxarm/${mirror_alarm_suffix}"
        else
            repo_urls['archlinuxarm']='http://mirror.archlinuxarm.org/'"${mirror_alarm_suffix}"
        fi
    fi
    declare -gn repo_url_base=repo_urls['archlinuxarm']
    bootstrap_pkgs+=('archlinuxarm-keyring')
}

distro_loongarchlinux() {
    distro_stylised='Loong Arch Linux'
    distro_safe='loongarchlinux'
    require_arch_target "${distro_stylised}" loong64
    distro_common
    if [[ -z "${repo_urls['loongarchlinux']:-}" ]]; then
        if [[ "${repo_url_parent}" ]]; then
            repo_urls['loongarchlinux']="${repo_url_parent}"'/loongarch/archlinux/$repo/os/$arch'
        else
            log_error \
                'Loong Arch Linux does not have a globally GeoIP-based mirror'\
                'and a local mirror must be defined through either'\
                '--repo-url-loongarchlinux or --repo-url-parent.'\
                'Please choose one from'\
                'https://loongarchlinux.org/pages/download'\
                'or use your own local mirror.'
            return 1
        fi
    fi
    declare -gn repo_url_base=repo_urls['loongarchlinux']
}

distro_archriscv() {
    distro_stylised='Arch Linux RISC-V'
    distro_safe='archriscv'
    require_arch_target "${distro_stylised}" riscv64
    distro_common
    if [[ -z "${repo_urls['archriscv']:-}" ]]; then
        if [[ "${repo_url_parent}" ]]; then
            repo_urls['archriscv']="${repo_url_parent}"'/archriscv/repo/$repo'
        else
            repo_urls['archriscv']='https://riscv.mirror.pkgbuild.com/repo/$repo'
        fi
    fi
    declare -gn repo_url_base=repo_urls['archriscv']
}

help_distro() {
    if [[ "${log_enabled['info']}" ]]; then
        log_info 'Supported distro and their supported target architectures:'
        echo 'Arch Linux (archlinux, alias: arch): x86_64'
        echo 'Arch Linux 32 (archlinux32, alias: arch32): i486, pentium4, i686'
        echo 'Arch Linux ARN (archlinuxarm, alias: archarm, alarm): armv7h, aarch64'
        echo 'Loong Arch Linux (loongarchlinux, alias: loongarch): '\
            'loongarch64(rewritten to loong64), loong64'
        echo 'Arch Linux RISC-V (archriscv, archlinuxriscv): riscv64'
    fi
}

# SET: mirror_formatted
mirror_format() { #1 mirror url, #2 repo, #3 arch
    local mirror="${1/\$repo/$2}"
    mirror_formatted="${mirror/\$arch/$3}"
}

configure_environment() {
    export LANG=C
    time_start_aimager=$(date +%s) || time_start_aimager=''
}

configure_board() {
    local board_func="board_${board/-/_}"
    if [[ $(type -t "${board_func}") == function ]]; then
        "${board_func}"
    else
        log_error \
            "Board '${board}' is not supported, pass --board help to get"\
            "a list of supported boards"
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
        log_error \
            "Unsupported distro '${distro}', use --disto help to check"\
            "the list of supported distros"
        return 1
        ;;
    esac
}

configure_repo() {
    local repo
    for repo in "${add_repos[@]}"; do
        "repo_${repo}"
    done
}

configure_persistent() {
    configure_board
    configure_distro
    configure_repo
}

configure_architecture() {
    if [[ "${arch_host}" == 'loongarch64' ]]; then
        arch_host='loong64'
    fi
    if [[ "${arch_target}" == 'loongarch64' ]]; then
        arch_target='loong64'
    fi
    if [[ "${arch_host}" != "${arch_target}" ]]; then
        arch_cross=1
    else
        arch_cross=0
    fi
}

configure_build() {
    if [[ -z "${build_id}" ]]; then
        build_id="${distro_safe}-${arch_target}-${board}-$(date +%Y%m%d%H%M%S)"
    fi
    log_info "Build ID is '${build_id}'"
    path_build=cache/build."${build_id}"
    log_info "Build folder is '${path_build}'"
    path_etc="${path_build}/etc"
    path_root="${path_build}/root"
    mkdir -p "${path_build}"/{bin,etc,root}
    log_info "Root mountpoint is '${path_root}'"
}

configure_out() {
    if [[ -z "${out_prefix}" ]]; then
        out_prefix="out/${build_id}-"
        log_warn \
            "Output prefix not set, generated as '${out_prefix}'"
    fi
    if [[ "${out_prefix}" == */* ]]; then
        log_info \
            "Output prefix contains folder, pre-creating it..."
        mkdir -p "${out_prefix%/*}"
    fi
}

size_mb_from_sector_or_human_readable() {
    local size="${1,,}"
    local multiply=1
    case "${size}" in
    *ib)
        multiply=1024
        size="${size::-2}"
        ;;
    *b)
        multiply=1000
        size="${size::-1}"
        ;;
    esac
    case "${size: -1}" in
    k)
        multiply=$(( "${multiply}" * 1024 ))
        size="${size::-1}"
        ;;
    m)
        multiply=$(( "${multiply}" * 1048576 ))
        size="${size::-1}"
        ;;
    g)
        multiply=$(( "${multiply}" * 1073741824 ))
        size="${size::-1}"
        ;;
    t)
        multiply=$(( "${multiply}" * 1099511627776 ))
        size="${size::-1}"
        ;;
    p)
        multiply=$(( "${multiply}" * 1125899906842624 ))
        size="${size::-1}"
        ;;
    e)
        multiply=$(( "${multiply}" * 1152921504606846976 ))
        size="${size::-1}"
        ;;
    0|1|2|3|4|5|6|7|8|9)
        multiply=$(( "${multiply}" * 512))
        ;;
    *)
        {
            log_error "Unknown suffix ${size: -1}"
        } >&2
        return 1
        ;;
    esac
    echo $(( ( "${size}" * "${multiply}" + 1048575) / 1048576 ))
}

size_mb_extract_from_sfdisk_part() { #1: line, 2: name (size/offset)
    local size=$(echo "$1" | sed -n \
        's/^\(.\+,\)\? *'"$2"'= *\([0-9]\+\([KkMmGgTtPpEeZzYy]\(i\?[Bb]\)\?\)\?\)\(,.*\)\?$/\2/p')
    if [[ "${size}" ]]; then
        size_mb_from_sector_or_human_readable "${size}"
    fi
}

configure_table() {
    log_info 'Configuring partition table...'
    case "${table}" in
    '@'*)
        log_info \
            "Reading sfdisk-dump-like from '${table:1}'..."
        table=$(<"${table:1}")
        ;;
    '='*)
        local table_func="${table:1}"
        log_info "Using common table '${table_func}'" 
        local table_func="table_common_${table_func/-/_}"
        if [[ $(type -t "${table_func}") == function ]]; then
            table=$("${table_func}")
        else
            log_error \
                "Common table '${table}' is not supported, pass --table help"\
                "to get a list of pre-defined common tabless"
            return 1
        fi
        ;;
    '')
        log_warn \
            'Table not defined, please define it with --table'
            # return 1
        ;;
    esac
    log_info "Using the following partition table: ${table}"
    table_part_orders=()
    # declare -gA table_part_names
    declare -gA table_part_infos
    declare -gA table_part_sizes
    declare -gA table_part_offsets
    declare -gA table_part_types
    declare -gA table_part_uuids
    local line part_order part_order part_info part_type part_uuid
    while read line; do
        [[ "${line,,}" =~ ^aimager@(boot|root|home|swap): ]] || continue
        part_order="${line:8:4}"
        if [[ " ${table_part_orders[*]} " == *" ${part_order} "* ]]; then
            log_error \
                "Duplicated part definition for ${part_order}"
            return 1
        fi
        table_part_orders+=("${part_order}")
        part_info="${line#*:}"
        table_part_sizes["${part_order}"]=$(
            size_mb_extract_from_sfdisk_part "${part_info}" 'size')
        table_part_offsets["${part_order}"]=$(
            size_mb_extract_from_sfdisk_part "${part_info}" 'offset')
        part_type=$(echo "${part_info}" | sed -n \
            's/^.\+, *type= *\([^,]\+\)\(,.*\)\?$/\1/p')
        if [[ "${part_type}" == '"'*'"' ]]; then
            table_part_types["${part_order}"]="${part_type:1:-1}"
        else
            table_part_types["${part_order}"]="${part_type}"
        fi
        table_part_infos["${part_order}"]="${part_info}"
        part_uuid=$(uuidgen)
        if [[ "${part_order}" == 'boot' ]]; then
            part_uuid="${part_uuid::8}"
            part_uuid="${part_uuid^^}"
            part_uuid="${part_uuid::4}-${part_uuid:4}"
        fi
        table_part_uuids["${part_order}"]="${part_uuid}"
    done <<< "${table}"
    if $(grep -q '^label: *gpt$' <<< "${table}"); then
        table_label=gpt
        local table_preserve_lbas=33
    else
        table_label=dos
        local table_preserve_lbas=0
    fi
    local last_lba=$(echo "${table}" | sed -n 's/^last-lba: \(.\+\)$/\1/p')
    if [[ "${last_lba}" ]]; then
        table_size=$(( 
            (
                ( 
                    "${last_lba}" + "${table_preserve_lbas}" + 1 
                ) * 512 + 1048575
            ) / 1048576
        ))
    else
        local part_end_last=$(
            echo "${table}" | sed -n 's/^first-lba: \(.\+\)$/\1/p')
        part_end_last=$(( ("${part_end_last:-2048}" * 512 + 1048575) / 1048576))
        local part_end_this
        for part_order in "${table_part_orders[@]}"; do
            table_part_offsets["${part_order}"]="${table_part_offsets["${part_order}"]:-"${part_end_last}"}"
            part_end_this=$((
                "${table_part_sizes["${part_order}"]:-0}" +
                "${table_part_offsets["${part_order}"]}"
            ))
            if (( "${part_end_this}" > "${part_end_last}" )); then
                part_end_last="${part_end_this}"
            fi
        done
        if [[ "${table_label}" == gpt ]]; then
            table_size=$(( "${part_end_last}" + 1 ))
        else
            table_size="${part_end_last}"
        fi
    fi
    log_info \
        "Table needs to be created on a disk with size at least ${table_size}M"
    if [[ "${log_enabled['info']}" ]]; then
        log_info 'Parsed partitions that aimager needs to create:'
        for part_order in "${table_part_orders[@]}"; do
            printf '%4s: size %6d MiB, offset %6d MiB, type %36s, uuid: %s\n' \
                "${part_order}" \
                "${table_part_sizes["${part_order}"]}" \
                "${table_part_offsets["${part_order}"]}" \
                "\"${table_part_types["${part_order}"]}\"" \
                "${table_part_uuids["${part_order}"]}" \

        done
    fi
}

configure_pkgs() {
    local pkgs_allowed=()
    local pkg
    for pkg in "${install_pkgs[@]}"; do
        case "${pkg}" in
        'booster'|'mkinitcpio'|'dracut')
            log_warn \
                "Removed '${pkg}' from install-pkg list: initrd-maker can only"\
                'be installed via --initrd-maker'
            ;;
        *)
            pkgs_allowed+=("${pkg}")
            ;;
        esac
    done
    install_pkgs=("${pkgs_allowed[@]}")
}

configure_dynamic() {
    # configure_initrd_maker
    configure_pkgs
    configure_architecture
    configure_build
    configure_out
    configure_table
}

configure() {
    configure_environment
    configure_persistent
    configure_dynamic
}

check() {
    check_executables
    check_date_locale
    log_info \
        "Aimager check complete."\
        "$(( $(date +%s) - ${time_start_aimager} )) seconds has elasped since"\
        "aimager started at $(date -d @"${time_start_aimager}")"
}

binfmt_check() {
    if [[ "${arch_target}" == loong64 ]]; then
        local arch_target=loongarch64
    fi
    if [[ "${arch_host}" == "${arch_target}" ]]; then
        log_warn \
            "Host architecture ${arch_host} =="\
            "target architecture ${arch_target},"\
            "no need nor use to run binfmt check"
    else
        local dir_aimager=$(readlink -f "$0")
        dir_aimager="${dir_aimager%/*}"
        log_warn \
            "Host architecture ${arch_host} !="\
            "target architecture ${arch_target},"\
            "checking if we have binfmt ready"
        log_info \
            "Running the following test command: "\
            "'sh -c \"cd '${dir_aimager}/test/binfmt';"\
            "./test.sh '${arch_target}'\"'"
        sh -c "cd '${dir_aimager}/test/binfmt'; ./test.sh '${arch_target}'"
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
        log_error \
            "Current context require us to run as root"\
            "but we are ${identity_name}"
        return 1
    fi
    if [[ "${identity_uid}" != '0' ]]; then
        log_error \
            "Current context require us to run as root (UID = 0)"\
            "but we have UID ${identity_uid}"
        return 1
    fi
    if [[ "${identity_gid}" != '0' ]]; then
        log_error \
            "Current context require us to run as root (GID = 0)"\
            "but we have GID ${identity_uid}"
        return 1
    fi
}

identity_require_non_root() {
    identity_get_name_uid_gid || return 1
    if [[ "${identity_name}" == 'root' ]]; then
        log_error \
            'Current context require us to NOT run as root but we are root'
        return 1
    fi
    if [[ "${identity_uid}" == '0' ]]; then
        log_error \
            'Current context require us to NOT run as root (UID != 0)'\
            'but we have UID 0'
        return 1
    fi
    if [[ "${identity_gid}" == '0' ]]; then
        log_error \
            'Current context require us to NOT run as root (GID != 0)'\
            'but we have GID 0'
        return 1
    fi
}

identity_require_mapped_root() {
    identity_require_root || return 1
    log_info \
        'Trying to write content under /sys to check whether we were'\
        'mapped to root or are real root.'\
        'Expecting a write failure...'
    if echo test > /sys/sys_write_test; then
        log_error \
            'We can write to /sys which means we have real root permission,'\
            'refuse to continue as real root'
        return 1
    else
        log_info \
            'We are not real root and were just mapped to root'\
            'in child namespace, everything looks good'
    fi
}

identity_get_subid() { #1: type
    declare -n identity_id="identity_$1"
    local identity_subids=($(
        sed -n 's/^'"${identity_name}"':\([0-9]\+:[0-9]\+\)$/\1/p' \
            "/etc/sub$1"))
    if [[ "${#identity_subids[@]}" == 0 ]]; then
        identity_get_subids=($(
            sed -n 's/^'"${identity_id}"':\([0-9]\+:[0-9]\+\)$/\1/p' \
                "/etc/sub$1"))
        if [[ "${#identity_subids[@]}" == 0 ]]; then
            log_error \
                "Could not find ${1}map record for"\
                "user ${identity_name} ($1 ${identity_id})"\
                "from /etc/sub$1"
            return 1
        fi
    fi
    identity_subid="${identity_subids[-1]}"
}

identity_get_subids() {
    # We need to map the user to 0:0, and others to 1:65535
    identity_get_subid uid
    identity_subuid_range="${identity_subid#*:}"
    if [[ "${identity_subuid_range}" -lt 65535 ]]; then
        log_error \
            "Recorded subuid range in /etc/subuid too short"\
            "(${identity_subuid_range} < 65535)"
        exit 1
    fi
    identity_subuid_start="${identity_subid%:*}"
    identity_get_subid gid
    identity_subgid_range="${identity_subid#*:}"
    if [[ "${identity_subgid_range}" -lt 65535 ]]; then
        log_error \
            "Recorded subgid range in /etc/subgid too short"\
            "(${identity_subgid_range} < 65535)"
        exit 1
    fi
    identity_subgid_start="${identity_subid%:*}"
}

child_wait() {
    log_debug \
        "Child $$ started and waiting for parent to map us..."
    local i mapped=''
    for i in {0..10}; do
        if identity_require_mapped_root; then
            mapped='yes'
            break
        fi
        log_info 'Waiting for parent to map us...'
        sleep 1
    done
    if [[ -z "${mapped}" ]]; then
        log_error \
            'Give up after waiting for 10 seconds yet parents fail to map us'
        return 1
    fi
    log_debug 'Child wait complete'
}

child_fs() {
    log_info 'Handling child rootfs...'
    rm -rf "${path_root}"
    mkdir "${path_root}"
    if [[ "${tmpfs_root_options}" ]]; then
        mount -t tmpfs -o "${tmpfs_root_options}" tmpfs-root "${path_root}"
    else
        mount "${path_root}" "${path_root}" -o bind
    fi
    mkdir -p "${path_root}"/{boot,dev,etc/pacman.d,proc,run,sys,tmp,var/{cache/pacman/pkg,lib/pacman,log}}
    mount tmpfs-dev "${path_root}"/dev -t tmpfs -o mode=0755,nosuid
    mount tmpfs-sys "${path_root}"/sys -t tmpfs -o mode=0755,nosuid
    mkdir -p "${path_root}"/{dev/{shm,pts},sys/module}
    chmod 1777 "${path_root}"/{dev/shm,tmp}
    chmod 555 "${path_root}"/{proc,sys}
    mount proc "${path_root}"/proc -t proc -o nosuid,noexec,nodev
    mount devpts "${path_root}"/dev/pts -t devpts \
        -o mode=0620,gid=5,nosuid,noexec
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
    if [[ "${log_enabled['debug']}" ]]; then
        log_debug 'Child rootfs mountinfo is as follows:'
        local prefix_mount=$(readlink -f "${path_root}")
        grep '^\([0-9]\+ \)\{2\}[0-9]\+:[0-9]\+ [^ ]\+ '"${prefix_mount}" \
            /proc/self/mountinfo
    fi
}

child_check_binfmt() {
    if (( "${arch_cross}" )); then
        log_info \
            "Entering chroot to run the minimum executeble 'true' to check if"\
            "QEMU binfmt works properly"
        chroot "${path_root}" true
    fi
}

child_init_reuse() {
    log_info "Reusing root tar ${reuse_root_tar}"
    bsdtar --acls --xattrs -xpf "${reuse_root_tar}" -C "${path_root}"
    child_check_binfmt
}

child_init_keyring() {
    if [[ ! -f "${keyring_archive}" ]]; then
        local path_chroot="${path_root}"
        if [[ "${keyring_helper}" ]]; then
            log_info \
                "Borrowing keyring manager from root archive"\
                "'${keyring_helper}' to sub /mnt ..."
            if [[ ! -f "${keyring_helper}" ]]; then
                log_error \
                    "'${keyring_helper}' is not a file (and certainly not a"\
                    'root archive), can not figure out how to borrow'\
                    'keyring managers from it'
                return 1
            fi
            mkdir -p "${path_root}"/{etc/pacman.d/gnupg,usr/share/pacman/keyrings,mnt/{dev,proc,etc/pacman.d/gnupg,usr/share/pacman/keyrings}}
            bsdtar --acls --xattrs -xpf "${keyring_helper}" \
                -C "${path_root}/mnt" \
                --exclude 'etc/pacman.d/gnupg' \
                'bin' 'etc/pacman*' 'lib*' \
                'usr/bin' 'usr/lib/getconf' 'usr/lib/*.so*' 'usr/share/makepkg'
            mount -o bind "${path_root}"{,/mnt}/dev
            mount -o bind "${path_root}"{,/mnt}/proc
            mount -o bind "${path_root}"{,/mnt}/etc/pacman.d/gnupg
            mount -o bind "${path_root}"{,/mnt}/usr/share/pacman/keyrings
            path_chroot+='/mnt'
        elif (( ${arch_cross} )); then
            log_warn \
                "Initializing and populating keyring '${keyring_id}' for the"\
                "first time cross-architecture (from arch '${arch_host}' to"\
                "arch '${arch_target}') using target keyring managers. This"\
                "might take a very long time as gpg and its calculation for"\
                "encryption/decryption/hashing needs to be handled by QEMU."\
                "To speed this up consider pass --keyring-helper to borrow"\
                "keyring managers from a previously created rootfs archive for"\
                "the native architecture (yours is '${arch_host}')."
        fi
        log_info \
            "Initializing keyring '${keyring_id}' for the first time..."
        chroot "${path_chroot}" pacman-key --init
        log_info \
            "Populating keyring '${keyring_id}' for the first time..."
        chroot "${path_chroot}" pacman-key --populate
    fi
    mkdir -p cache/keyring
    log_info \
        "Creating keyring backup archive '${keyring_archive}'..."
    bsdtar --acls --xattrs -cpf "${keyring_archive}.temp" -C "${path_keyring}" \
        --exclude ./S.\* .
    mv "${keyring_archive}"{.temp,}
}

# This can only be done AFTER keyrings installed, need to swap order around
child_init_bootstrap() {
    pacman -Sy --config "${path_etc}/pacman-loose.conf" \
        --noconfirm "${bootstrap_pkgs[@]}"
    child_check_binfmt
    local keyring_id=$(
        tar --directory "${path_root}/usr/share/pacman/keyrings" --owner root \
            --group root --mtime 1970-01-01 --create . |
            md5sum
    )
    keyring_id="md5-${keyring_id::32}"
    log_info "Keyring ID is ${keyring_id}"
    local keyring_archive=cache/keyring/"${keyring_id}".tar
    local path_keyring="${path_root}/etc/pacman.d/gnupg"
    if [[ -f "${keyring_archive}" ]]; then
        log_info \
            "Reusing keyring backup archive '${keyring_archive}'..."
        mkdir -p "${path_keyring}"
        bsdtar --acls --xattrs -xpf "${keyring_archive}" -C "${path_keyring}"
    else
        log_warn \
            "This seems our first attempt to install for ${keyring_id},"\
            "need to initialize the keyring..."
        child_init_keyring
    fi
    log_info "Going back to verify bootstrap packages..."
    pacman -S --config "${path_etc}/pacman-strict.conf" \
        --downloadonly --noconfirm \
        $(
            pacman -Q --config "${path_etc}/pacman-loose.conf" | cut -d ' ' -f 1
        )
}

child_init() {
    if [[ "${reuse_root_tar}" ]]; then
        child_init_reuse
    else
        child_init_bootstrap
    fi
}

child_initrd_set_universal_dracut() {
    log_fatal 'Not implemented yet'
    return 1
}

child_setup_initrd_maker() {
    log_info \
        'Checking if we need to install and hack initrd maker...'
    if pacman -T --config "${path_etc}/pacman-strict.conf" initramfs \
        > /dev/null
    then
        return
    fi
    if [[ "${initrd_maker}" ]]; then
        log_info "Installing initrd maker ${initrd_maker}..."
        pacman -S --config "${path_etc}/pacman-strict.conf" --noconfirm \
            "${initrd_maker}"
    else
        log_warn \
            'Not installing any initrd maker! If you really are installing any'\
            'kernel pacakges, it is recommended to use --initrd-maker to let'\
            'aimager install the initrd maker so it could do some workarounds'\
            'like only enabling the universal config.'
    fi
    case "${initrd_maker}" in
    'booster')
        cp "${path_root}/etc/booster.yaml"{,.pacsave}
        echo 'universal: true' > "${path_root}/etc/booster.yaml"
        ;;
    'mkinitcpio')
        cp "${path_root}/usr/share/mkinitcpio/hook.preset"{,.pacsave}
        sed -i "s/^PRESETS=.\+/PRESETS=('fallback')/" \
            "${path_root}/usr/share/mkinitcpio/hook.preset"
        ;;
    'dracut')
        child_initrd_set_universal_dracut
        ;;
    '')
        ;;
    *)
        log_error \
            "Unknown initrd maker ${initrd_maker}, it could only be one of the"\
            'following: booster, mkinitcpio, dracut'
            return 1
        ;;
    esac
}

child_revert_initrd_maker() {
    case "${initrd_maker}" in
    'booster')
        [[ -f "${path_root}/etc/booster.yaml.pacsave" ]] || return
        mv "${path_root}/etc/booster.yaml"{.pacsave,}
        ;;
    'mkinitcpio')
        [[ -f "${path_root}/usr/share/mkinitcpio/hook.preset.pacsave" ]] || 
            return
        mv "${path_root}/usr/share/mkinitcpio/hook.preset"{.pacsave,}
        local preset kernel
        for preset in "${path_root}"/etc/mkinitcpio.d/*.preset; do
            kernel="${preset##*/}"
            kernel="${kernel%.preset}"
            sed "s|%PKGBASE%|${kernel}|g" \
                "${path_root}/usr/share/mkinitcpio/hook.preset" > "${preset}"
        done
        ;;
    'dracut')
        child_initrd_set_universal_dracut
        ;;
    esac
}

child_setup_fstab() {
    local part_order part_mount part_type part_options part_pass
    for part_order in "${table_part_orders[@]}"; do
        case "${part_order}" in
        'root')
            part_mount='/'
            ;;
        'swap')
            part_mount='none'
            ;;
        *)
            part_mount="/${part_order}"
            ;;
        esac
        case "${part_order}" in
        'boot')
            part_type='vfat'
            part_options='rw,defaults'
            part_pass=2
            ;;
        'swap')
            part_type='swap'
            part_options='none'
            part_pass=0
            ;;
        *)
            part_type='ext4'
            part_options='rw,noatime,defaults'
            part_pass=1
            ;;
        esac
        printf '# aimager-part: %s\nUUID=%-36s %-5s %-5s %-20s 0 %u\n' \
            "${table_part_infos["${part_order}"]}" \
            "${table_part_uuids["${part_order}"]}" \
            "${part_mount}" \
            "${part_type}" \
            "${part_options}" \
            "${part_pass}" \

    done >> "${path_root}/etc/fstab"
}

get_initrd_prefix() {
    case "${initrd_maker}" in
    mkinitcpio)
        initrd_prefix=initramfs-
        ;;
    booster)
        initrd_prefix=booster-
        ;;
    dracut)
        initrd_prefix=dracut-
        ;;
    *)
        log_error "Illegal initrd maker: ${initrd_maker}"
        return 1
        ;;
    esac
}

get_name_efi_removable() {
    case "${arch_target}" in
    'x86_64')
        name_efi_removable='BOOTX64.EFI'
        ;;
    'armv7h')
        name_efi_removable='BOOTARM.EFI'
        ;;
    'aarch64')
        name_efi_removable='BOOTAA64.EFI'
        ;;
    'i486'|'pentium4'|'i686')
        name_efi_removable='BOOTIA32.EFI'
        ;;
    'riscv64')
        name_efi_removable='BOOTRISCV64.EFI'
        ;;
    *)
        log_error "Cannot get name of EFI removable binary for ${arch_target}"
        ;;
    esac
}

get_append() {
    append="${appends[all]:-${appends["${kernel}"]:-${appends[default]:-}}}"
    if [[ "${append}" ]]; then
        append=" ${append}"
    fi
}

get_boot_prefix() {
    if [[ "${table_part_infos[boot]:-}" ]]; then
        boot_prefix=''
    else
        boot_prefix='/boot'
    fi
}

child_setup_bootloader_systemd_boot() {
    # we cannot use 'bootctl --graceful install' as --graceful has no effect:
    # systemd since 90cf998875a
    mkdir -p "${path_root}/boot/"{EFI/BOOT,loader/entries}
    local name_efi_removable
    get_name_efi_removable
    cp "${path_root}/"{"usr/lib/systemd/boot/efi/systemd-${name_efi_removable,,}","boot/EFI/BOOT/${name_efi_removable}"}
    echo type1 > "${path_root}/boot/loader/entries.srel"
    dd if=/dev/urandom of="${path_root}/boot/loader/random-seed" bs=32 count=1

    printf '%s %s\n' \
        'default' "${distro_safe}-${kernels[0]}.conf" \
        'timeout' '3' \
        > "${path_root}/boot/loader/loader.conf"

    local kernel boot_prefix initrd_prefix append fdtdir fdtfile
    get_boot_prefix
    get_initrd_prefix
    for kernel in "${kernels[@]}"; do
        get_append
        {
            echo "title ${distro_stylised}"
            echo "linux ${boot_prefix}/vmlinuz-${kernel}"
            printf "initrd ${boot_prefix}/%s\n" "${ucodes[@]}" "${initrd_prefix}${kernel}.img"
            fdtdir="/dtbs/${kernel}"
            if [[ -d "${path_root}/boot/${fdtdir}" ]]; then
                echo "fdtdir ${boot_prefix}${fdtdir}"
            fi
            case "${fdt:-}" in
            '/'*)
                echo "fdt ${boot_prefix}${fdt}"
                ;;
            '')
                ;;
            *)
                echo "fdt ${boot_prefix}${fdtdir}/${fdt}"
                ;;
            esac
            echo "options root=UUID=${table_part_uuids[root]} rw${append}"
        } > "${path_root}/boot/loader/entries/${distro_safe}-${kernel}.conf"
    done
}

child_setup_bootloader_extlinux() { #1 config
    mkdir -p "${1%/*}"
    local extlinux="$1"
    local format_indent0='%-12s%s\n'
    local format_indent1='    %-12s%s\n'
    printf "${format_indent0}" \
        'MENU TITLE' "${distro_stylised}" \
        'TIMEOUT' '30' \
        'DEFAULT' "${kernels[0]}" \
        > "${extlinux}"
    local kernel boot_prefix initrd_prefix append fdtdir fdtfile boot_prefix
    get_boot_prefix
    get_initrd_prefix
    for kernel in "${kernels[@]}"; do
        get_append
        {
            printf "${format_indent0}" 'LABEL' "${kernel}"
            printf "${format_indent1}" 'LINUX' "${boot_prefix}/vmlinuz-${kernel}"
            printf "    INITRD      ${boot_prefix}/%s\n" "${ucodes[@]}" "${initrd_prefix}${kernel}.img"
            fdtdir="/dtbs/${kernel}"
            if [[ -d "${path_root}/boot${fdtdir}" ]]; then
                printf "${format_indent1}" 'FDTDIR' "${boot_prefix}${fdtdir}"
            fi
            case "${fdt:-}" in
            '/'*)
                printf "${format_indent1}" 'FDT' "${boot_prefix}${fdt}"
                ;;
            '')
                ;;
            *)
                printf "${format_indent1}" 'FDT' "${boot_prefix}${fdtdir}/${fdt}"
                ;;
            esac
            printf "${format_indent1}" 'APPEND' "root=UUID=${table_part_uuids[root]} rw${append}"
        } >> "${extlinux}"
    done
}

create_part_boot_empty() {
    truncate -s "${table_part_sizes[boot]}"M "$1"
    mkfs.fat -i "${table_part_uuids[boot]::4}${table_part_uuids[boot]:5}" \
        ${mkfs_args[boot]:-} "$1"
}

child_setup_bootloader_syslinux() {
    if [[ "${table_label}" != 'dos' ]]; then
        log_error 'Table label != dos, cannot install syslinux'
        return 1
    fi
    if [[ -z "${table_part_infos[boot]:-}" ]]; then
        log_error 'No dedicated boot partition, cannot install syslinux'
        return 1
    fi
    mkdir -p "${path_root}/boot/syslinux"
    if [[ -f "${path_build}/head.img" ]]; then
        log_error 'There is already head.img, cannot install syslinux as it would not be the only one occupying disk head'
        return 1
    fi
    dd bs=440 count=1 conv=notrunc if="${path_root}/usr/lib/syslinux/bios/mbr.bin" of="${path_build}/head.img"
    local boot_img="${path_root}/tmp/boot.img"
    if [[ -f "${boot_img}" ]]; then
        log_error 'There is already boot.img, cannot install syslinux as it would not be the only one occupying boot partition head'
        return 1
    fi
    create_part_boot_empty "${boot_img}"
    mmd -i "${boot_img}" syslinux
    mcopy -oi "${boot_img}" "${path_root}/usr/lib/syslinux/bios/"*.c32 ::syslinux/
    chroot "${path_root}" syslinux -i /tmp/boot.img -d syslinux
    mv "${boot_img}" "${path_build}/boot.img"
    child_setup_bootloader_extlinux "${path_root}/boot/syslinux/syslinux.cfg"
}

child_setup_bootloader_u_boot() {
    log_warn 'U-boot installtion not implemented, only extlinux generated'
    child_setup_bootloader_extlinux "${path_root}/boot/extlinux/extlinux.conf"
}

child_setup_bootloader() {
    local bootloader bootloader_func
    for bootloader in "${bootloaders[@]}"; do
        bootloader_func="child_setup_bootloader_${bootloader/-/_}"
        if [[ $(type -t "${bootloader_func}") == function ]]; then
            "${bootloader_func}"
        else
            log_error "Bootloader '${bootloader}' is not supported, supported: " \
                'systemd-boot, syslinux, u-boot'
            return 1
        fi
    done
}

child_setup_hostname() {
    local hostname_safe=$(sed 's/[^A-Za-z0-9-]//' <<< "${hostname_original:-${board:-${distro_safe:-}}}")
    hostname_safe="${hostname_safe:-aimager}"
    hostname_safe="${hostname_safe,,}"

    echo "${hostname_safe,,}" > "${path_root}/etc/hostname"
}

child_setup_locale() {
    local locale_add locale_use= pattern has_locale=
    for locale_add in "${locales[@]}"; do
        pattern+='s/#\('"${locale_add}"'\) /\1 /;'
        locale_use="${locale_use:-${locale_add}}"
        has_locale='y'
    done
    if [[ "${has_locale}" ]]; then
        sed -i "${pattern}" "${path_root}/etc/locale.gen"
        chroot "${path_root}" locale-gen
        echo "${locale_use}" > "${path_root}/etc/locale.conf"
    fi
}

child_setup() {
    child_setup_initrd_maker
    if [[ "${install_pkgs[*]}${kernels[*]}${!ucodes[*]}${bootloader_pkgs[*]}" ]]; then
        log_info \
            "Installing packages: ${install_pkgs[*]} ${kernels[*]} ${!ucodes[*]}"
        pacman -S --config "${path_etc}/pacman-strict.conf" --noconfirm \
            --needed "${install_pkgs[@]}" "${kernels[@]}" "${!ucodes[@]}" "${bootloader_pkgs[@]}"
    fi
    child_revert_initrd_maker
    if [[ "${pacman_conf_append}" ]]; then
        echo "${pacman_conf_append}" >> "${path_root}/etc/pacman.conf"
    fi
    child_setup_fstab
    child_setup_bootloader
    child_setup_hostname
    child_setup_locale
    local overlay
    for overlay in "${overlays[@]}"; do
        bsdtar --acls --xattrs -xpf "${overlay}" -C "${path_root}"
    done
}

child_out() {
    local create
    declare -A created
    for create in "${creates[@]}"; do
        create="${create/-/_}"
        create="${create/./_}"
        "create_${create}"
    done
}

child_clean() {
    log_info 'Child cleaning...'
    log_info 'Killing child gpg-agent...'
    chroot "${path_root}" pkill -SIGINT --echo '^gpg-agent$' || true
    if [[ "${tmpfs_root_options}" ]]; then
        log_info 'Using tmpfs, skipped cleaning'
        return
    fi
    # log_info 'Syncing after killing gpg-agent...'
    # sync
    log_info 'Umounting rootfs...'
    umount -R "${path_root}"
    log_info 'Deleting rootfs leftovers...'
    rm -rf "${path_root}"
}

child() {
    child_wait
    if (( "${run_clean_builds}" )); then
        log_info 'Cleaning builds...'
        rm -rf cache/build.*
        return
    fi
    local signal
    for signal in INT TERM KILL; do
        trap "
            echo '[child.sh:WARN] SIG${signal} received, bad exiting'
            exit 1" "${signal}"
    done
    child_fs
    child_init
    if (( "${run_only_backup_keyring}" )); then
        trap - INT TERM KILL
    else
        child_setup
        trap - INT TERM KILL
        child_out
    fi
    child_clean
    log_info 'Child exiting!!'
}

prepare_child_context() {
    {
        echo 'set -euo pipefail'
        declare -p | grep 'declare -[-fFgIpaAilnrtux]\+ [a-z_]'
        declare -f
        echo 'child'
    } >  "${path_build}/bin/child.sh"
}

run_child_and_wait_sync() {
    log_info \
        'System unshare support --map-users and --map-groups,'\
        'using unshare itself to map'
    log_info 'Spwaning child (sync)...'
    unshare --user --pid --mount --fork \
        --map-root-user \
        --map-users="${map_users}" \
        --map-groups="${map_groups}" \
        -- \
        /bin/bash "${path_build}/bin/child.sh"
}

run_child_and_wait_async() {
    log_info \
        'System unshare does not support --map-users and --map-groups,'\
        'mapping manually using newuidmap and newgidmap'
    log_info 'Spwaning child (async)...'
    unshare --user --pid --mount --fork --kill-child=SIGTERM \
        /bin/bash "${path_build}/bin/child.sh"  &
    pid_child="$!"
    local signal
    for signal in INT TERM EXIT; do
        trap "
            echo '[aimager.sh:WARN] SIG${signal} received, killing ${pid_child}'
            kill -s SIGKILL '${pid_child}'
        " "${signal}"
    done
    sleep 1
    newuidmap "${pid_child}" \
        0 "${identity_uid}" 1 \
        1 "${identity_subuid_start}" "${identity_subuid_range}"
    newgidmap "${pid_child}" \
        0 "${identity_gid}" 1 \
        1 "${identity_subgid_start}" "${identity_subgid_range}"
    log_info \
        "Mapped UIDs and GIDs for child ${pid_child}, "\
        "waiting for it to finish..."
    wait "${pid_child}"
    trap - INT TERM EXIT
    log_info "Child ${pid_child} finished successfully"
}

run_child_and_wait() {
    if (( "${async_child}" )); then
        log_warn 'Forcing to spwan child in async way'
        run_child_and_wait_async
        return
    fi
    local unshare_fields=$(
        unshare --help | sed 's/^ \+--map-users=\(.\+\)$/\1/p' -n)
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

clean() {
    log_info 'Cleaning up before exiting...'
    rm -rf "${path_build}"
}

work() {
    log_info \
        "Building for distro '${distro}' to architecture '${arch_target}'"\
        "from architecture '${arch_host}'"
    prepare_pacman_conf
    prepare_child_context
    if (( "${run_only_prepare_child}" )); then
        log_info 'Early exiting before spawning child ...'
        return
    fi
    identity_get_subids
    run_child_and_wait
    clean
}

aimager() {
    identity_require_non_root
    configure
    if  (( "${run_binfmt_check}" )); then
        binfmt_check
        return
    fi
    check
    work
    log_info 'aimager exiting!!'
}

create_part_boot_img() {
    if [[ "${created['part-boot.img']:-}" ]]; then
        return
    fi
    local path_out="${out_prefix}part-boot.img"
    log_info "Creating boot partition image '${path_out}'..."
    if [[ -f "${path_build}/boot.img" ]]; then
        mv "${path_build}/boot.img" "${path_out}.temp"
    else
        create_part_boot_empty "${path_out}.temp"
    fi
    mcopy -osi "${path_out}.temp" "${path_root}/boot/"* ::
    mv "${path_out}"{.temp,}
    created['part-boot.img']='y'
    log_info "Created boot partition image '${path_out}'"
}

create_part_root_img() {
    if [[ "${created['part-root.img']:-}" ]]; then
        return
    fi
    local path_out="${out_prefix}part-root.img"
    log_info "Creating root partition image '${path_out}'..."
    truncate -s "${table_part_sizes[root]}"M "${path_out}.temp"
    local shadow
    local shadows=(dev mnt proc sys)
    if [[ "${table_part_sizes[boot]:-}" ]]; then
        shadows+=(boot)
    fi
    if [[ "${table_part_sizes[home]:-}" ]]; then
        shadows+=(home)
    fi
    for shadow in "${shadows[@]}"; do
        mount -t tmpfs shadow-"${shadow}" "${path_root}/${shadow}"
    done
    mkfs.ext4 -d "${path_root}" -U "${table_part_uuids[root]}" \
        ${mkfs_args[root]:-} "${path_out}.temp"
    for shadow in "${shadows[@]}"; do
        umount "${path_root}/${shadow}"
    done
    mv "${path_out}"{.temp,}
    created['part-root.img']='y'
    log_info "Created root partition image '${path_out}'"
}

create_part_home_img() {
    if [[ "${created['part-home.img']:-}" ]]; then
        return
    fi
    local path_out="${out_prefix}part-home.img"
    log_info "Creating home partition image '${path_out}'..."
    truncate -s "${table_part_sizes[home]}"M "${path_out}.temp"
    mkfs.ext4 -d "${path_root}/home" -U "${table_part_uuids[home]}" \
        ${mkfs_args[home]:-} "${path_out}.temp"
    mv "${path_out}"{.temp,}
    created['part-home.img']='y'
    log_info "Created home partition image '${path_out}'"
}

create_disk_img() {
    if [[ "${created['disk.img']:-}" ]]; then
        return
    fi
    local path_out="${out_prefix}disk.img"
    if [[ -f "${path_build}/head.img" ]]; then
        mv "${path_build}/head.img" "${path_out}.temp"
    fi
    log_info "Creating disk image '${path_out}'..."
    truncate -s "${table_size}"M "${path_out}".temp
    local part_order
    sfdisk "${path_out}".temp <<< "${table}"
    for part_order in "${table_part_orders[@]}"; do
        create_part_"${part_order}"_img
        log_info \
            "Writing partition ${part_order} into disk image '${path_out}'..."
        dd if="${out_prefix}part-${part_order}.img" of="${path_out}.temp" \
            bs=1M seek="${table_part_offsets["${part_order}"]}" conv=notrunc
    done
    mv "${path_out}"{.temp,}
    created['part-home.img']='y'
    log_info "Created home partition image '${path_out}'"
}

create_root_tar() {
    if [[ "${created['root.tar']:-}" ]]; then
        return
    fi
    local path_out="${out_prefix}root.tar"
    log_info "Creating root archive '${path_out}'..."
    bsdtar --acls --xattrs -cpf "${path_out}.temp" -C "${path_root}" \
        --exclude './dev' --exclude './mnt' --exclude './proc' \
        --exclude './sys' --exclude './etc/pacman.d/gnupg/S.*' \
        .
    mv "${path_out}"{.temp,}
    created['root.tar']='y'
    log_info "Created root archive '${path_out}'"
}

create_keyring_helper_tar() {
    if [[ "${created['keyring-helper.tar']:-}" ]]; then
        return
    fi
    local path_out="${out_prefix}keyring-helper.tar"
    log_info "Creating keyring helper '${path_out}'..."
    local filters=(
        --include './bin' --include './etc/pacman*' --include './lib*'
        --include './usr/bin' --include './usr/lib/getconf'
        --include './usr/lib/*.so*' --include './usr/share/makepkg'
        --exclude './etc/pacman.d/gnupg/*'
    )
    if [[ "${created['root.tar']:-}" ]]; then
        log_info 'Reusing root.tar created in the same run...'
        bsdtar --acls --xattrs -cpf "${path_out}.temp" "${filters[@]}" \
            "@${out_prefix}root.tar"
    else
        bsdtar --acls --xattrs -cp -C "${path_root}" \
            --exclude './dev' --exclude './mnt' --exclude './proc' \
            --exclude './sys' --exclude './etc/pacman.d/gnupg/*' \
            . |
            bsdtar --acls --xattrs -cpf "${path_out}.temp" "${filters[@]}" '@-'
    fi
    mv "${path_out}"{.temp,}
    created['keyring-helper.tar']='y'
    log_info "Created keyring helper '${path_out}'"
}

help_create() {
    local name prefix=create_ creates=()
    for name in $(declare -F); do
        if [[ "${name}" == "${prefix}"* && ${#name} -gt 7 ]]; then
            creates+=("${name:7}")
        fi
    done
    log_info \
        "Available to-be-created targets (_, -, . are inter-changable):"
    printf '%s:\n\t%s\n' \
        'part-boot.img' \
            'the FAT boot partition image, containing everything in rootfs under /boot' \
        'part-root.img' \
            'the ext4 root partition image, containing everything in rootfs, except /boot and /home if they were defined in table' \
        'part-home.img' \
            'the ext4 home partition image, containing everything in rootfs under /home' \
        'disk.img' \
            'a partitioned disk image file containing define partition table, containing at least part-root.img, and possibly part-boot.img and/or part-home.img if they were defined in table' \
        'root.tar' \
            'a tarball containing everything in rootfs' \

    return
}

help_aimager() {
    echo 'Usage:'
    echo "  $0 ([--option] ([option argument])) ..."
    local formatter='    --%-25s %s\n'

    printf '\nHost options:\n'
    printf -- "${formatter}" \
        'arch-host [arch]' 'host architecture; default: result of `uname -m`' \

    printf '\nImage overall options:\n'
    printf -- "${formatter}" \
        'arch-target [arch]' 'target architecure; default: result of `uname -m`' \
        'arch [arch]' 'alias to --arch-target' \
        'board [board]' 'board, would call corresponding built-in board definition to define other options, if no board is defined only rootfs tarball is created, pass "help" to get the list of supported boards, pass "help=[board]" to get the board definition; default: none' \
        'build-id [build id]' 'a unique build id; default: [distro safe name]-[target architecture]-[board]-[yyyymmddhhmmss]' \
        'distro [distro]*' 'distro, required, passing "help" to get the list of supported distros, pass "help=[distro]" to get the distro definition' \
        'out-prefix [prefix]' 'prefix to output archives and images, default: out/[build id]-'\

    printf '\nBootstrapping options:\n'
    printf -- "${formatter}" \
        'add-repo [repo]' 'add an addtional repo, usually third party, pass help to get the list of built-in third party repos, pass help=[repo] to get the repo definition, can be specified multiple times'\
        'add-repos [repos]' 'comma seperated list of repos, shorthand for multiple --add-repo, can be specified multiple times'\
        'repo-core [repo]' 'the name of the distro core repo, this is used to dump etc/pacman.conf from the pacman package to prepare pacman-strict.conf and pacman-loose.conf; default: core' \
        'repo-url-parent [parent]' 'the URL parent of repos, usually public mirror sites fast and close to the builder, used to generate the whole repo URL, if this is not set then global mirror URL would be used if that repo has defined such, some repos need always this to be set as they do not provide a global URL, note this has no effect on the pacman.conf in final image but only for building; default: [none]; e.g.: https://mirrors.mit.edu' \
        'repo-url-[name] [url]' 'specify the full URL for a certain repo, should be in the format used in pacman.conf Server= definition, if this is not set for a repo then it would fall back to --repo-url-parent logic (see above), for third-party repos the name is exactly its name and for offiical repos the name is exactly the undercased distro name (first name in bracket in --distro help), note this has no effect on the pacman.conf in final image but only for building; default: [none]; e.g.: --repo-url-archlinux '"'"'https://mirrors.xtom.com/archlinux/$repo/os/$arch/'"'" \
        'repos-base [repo]' 'comma seperated list of base repos, order matters, if this is not set then it is generated from the pacman package dumped from core repo, as the upstream list might change please only set this when you really want a different list from upstream such as when you want to enable a testing repo, e.g., core-testing,core,extra-testing,extra,multilib-testing,multilib default: [none]' \
        'reuse-root-tar [tar]' 'reuse a tar to skip root bootstrapping, only do package installation and later steps' \

    printf '\nSetup options:\n'
    printf -- "${formatter}" \
        'initrd-maker [maker]' 'initrd maker: booster(default)/mkinitcpio/dracut, initrd-maker is installed before all other packages after bootstrapping so aimager could config it to only build universal images, and it would only be installed if initramfs virtual package has no provider, that is, if you use --reuse-root to do incremental build then in most cases later --initrd-maker has no use. ' \
        'install-pkg [pkg]' 'install a generic package after bootstrapping, can be specified multiple times, some packages would be filtered if listed here, these include: initrd-maker which should be declared in --initrd-maker, keyring which should be declared in --add-repo, kernel which should be declared in install-kernel, etc'\
        'install-pkgs [pkgs]' 'comma-seperated list of packages to install after bootstrapping, shorthand for multiple --install-pkg, can be specified multiple times'\
        'append-[kernel] [append]' 'append options to kernel cmdline after root=xxxx rw, specify [kernel] for a specific kernel, special [kernel] value: "all" for all kernels (replacing other), "default" for all kernels (being replaced by other)'\
        'locale [locale]' 'enable locale, can be specified multiple times, all locales would be enabled but only the first locale would be set in /etc/locale.conf, e.g. en_GB.UTF-8'\
        'locales [locales]' 'comma-seperated list of locales to enable, shothand for multiple --locale, can be specified multiple times, e.g. zh_CN.UTF-8,en_US.UTF-8'\
        'hostname [hostname]' 'unless specified, default: board name converted to lowercase then with only [a-z0-9-], or distro safe name, or empty'\
        'overlay [overlay]' 'path of overlay (a tar file), extracted to the target image after all other configuration is done, can be specified multiple-times' \
        'table [table]' 'either sfdisk-dump-like multi-line string, or @[path] to read such string from, or =[name] to use one of the built-in common tables, e.g. --table @mytable.sdisk.dump, --table =dos_16g_root. the table would be used by aimager to find the essential paritition infos, disk size, and later used as the input of sfdisk to create the table on disk image. aimager-specific partition definition lines should be prefixed with "aimager@[part]:" so aimager knows which partitions to use for boot, home, root, swap. pass "help" to check the list of built-in common tables. pass "help=[common table]" to show the built-in definition. e.g. pass "--table help=gpt_1g_esp_16g_root_x86_64" to get an idea of how the string should be prepared' \
        'mkfs-arg [part]=[arg]' 'addtional args passed when creating fs, part could be boot, home, root, swap'\

    printf '\nBuilder behaviour options:\n'
    printf -- "${formatter}" \
        'async-child' 'use always the async way to unshare and wait for child (basically unshare in a background job and we map in main Bash instance then wait), instead of trying to use the sync way to unshare and wait for child (basically unshare itself does the mapping and we call it in a blocking way) when unshare is new enough and async otherwise' \
        'freeze-pacman-config' 'do not re-generate ${path_etc}/pacman-loose.conf and ${path_etc}/pacman-strict.conf from repo' \
        'freeze-pacman-static' 'for hosts that do not have system-provided pacman, do not update pacman-static online if we already downloaded it previously; this is strongly NOT recommended UNLESS you are doing continuous builds and re-using the same cache' \
        'keyring-helper [archive]' 'borrow keyring managers (pacman-key, gpg and other crypt libs) from a previously created root archive, or a helper-only archive created with `--create keyring-helper.tar`, native arch is the best, used during keyring initialization to avoid the bottleneck caused by calling gpg via QEMU. it is recommended to always use this if you are cross-building and the qemu-based gpg from target architecture runs too slow. currently the whole root archive would be extracted to sub /mnt, so use in caution when in combination with --tmpfs-root'\
        'tmpfs-root(=[options])' 'mount a tmpfs to root, instead of bind-mounting, pass only --tmpfs-root to use default mount options, pass --tmpfs-root=[options] to overwrite the tmpfs mounting options' \
        'use-pacman-static' 'always use pacman-static, even if we found pacman in PATH, mainly for debugging. if this is not set (default) then pacman-static would only be downloaded and used when we cannot find pacman'\

    printf '\nRun-target options:\n'
    printf -- "${formatter}" \
        'binfmt-check' 'run a binfmt check for the target architecture after configuring and early quit' \
        'clean-builds' 'clean builds and early quit'\
        'create [target]' 'create a certain target, artifact would be [out-prefix][target], can be specified multiple times, pass "help" to check for allowed to-be-created target, it is recommended to build always root.tar if possible'\
        'help' 'print this help message' \
        'only-backup-keyring' 'bootstrap, init and populate the keyring, backup, then early quit'\
        'only-prepare-child' 'early exit before spawning child, mainly for debugging' \

    printf '\nExamples:\n'
    printf -- '    %s\n    > ./aimager.sh %s\n' \
        'to create an Arch Linux rootfs:' \
            '--distro arch --create root.tar' \
        'to create an EFI-bootable Arch Linux iamge:' \
            '--board x64_uefi --create disk.img' \
        'to create an u-boot bootable Arch Linux ARM image for Orange Pi 5 Plus:' \
            '--board orangepi_5_plus --create disk.img' \

}

report_wrong_arg() { # $1: prefix, $2 original args collapsed, $3: remaining args
    echo "$1 $2"
    local args_remaining_collapsed="${@:3}"
    printf "%$(( ${#1} + ${#2} + 1 - ${#args_remaining_collapsed} ))s^"
    local len="${#3} - 2"
    while (( $len )); do
        echo -n '~'
        let len--
    done
    echo '^'
}

aimager_cli() {
    # declare -A config_dynamic
    # declare
    local args_original="$@"
    local splitted=()
    local bad_arg=0
    while (( $# > 0 )); do
        case "$1" in
        # Host options
        '--arch-host')
            arch_host="$2"
            shift
            ;;
        # Image overall options
        '--arch-target'|'--arch')
            arch_target="$2"
            shift
            ;;
        '--board')
            case "$2" in
            'help')
                help_board
                return
                ;;
            'help='*)
                help_board
                declare -fp "board_${2:5}"
                return
                ;;
            *)
                board="$2"
                shift
            esac
            ;;
        '--build-id')
            build_id="$2"
            shift
            ;;
        '--distro')
            case "$2" in
            'help')
                help_distro
                return
                ;;
            'help='*)
                help_distro
                declare -fp "distro_${2:5}"
                return
                ;;
            *)
                distro="$2"
                shift
            esac
            ;;
        '--out-prefix')
            out_prefix="$2"
            shift
            ;;
        # Boostrapping options
        '--add-repo')
            case "$2" in
            'help')
                help_repo
                return
                ;;
            'help='*)
                help_repo
                declare -fp "repo_${2:5}"
                return
                ;;
            *)
                add_repos+=("$2")
                shift
                ;;
            esac
            ;;
        '--add-repos')
            IFS=', ' read -r -a splitted <<< "$2"
            add_repos+=("${splitted[@]}")
            shift
            ;;
        '--repo-core')
            repo_core="$2"
            shift
            ;;
        '--repo-url-parent')
            repo_url_parent="$2"
            shift
            ;;
        '--repo-url-'*)
            repo_urls["${1:11}"]="$2"
            shift
            ;;
        '--repos-base')
            IFS=', ' read -r -a repos_base <<< "$2"
            shift
            ;;
        '--reuse-root-tar')
            reuse_root_tar="$2"
            shift
            ;;
        # Setup options
        '--initrd-maker')
            initrd_maker="$2"
            shift
            ;;
        '--install-pkg')
            install_pkgs+=("$2")
            shift
            ;;
        '--install-pkgs')
            IFS=', ' read -r -a splitted <<< "$2"
            install_pkgs+=("${splitted[@]}")
            shift
            ;;
        '--append-'*)
            appends["${1:9}"]="$2"
            shift
            ;;
        '--locale')
            locales+=("$2")
            shift
            ;;
        '--locales')
            IFS=',' read -r -a splitted <<< "$2"
            locales+=("${splitted[@]}")
            shift
            ;;
        '--hostname')
            hostname_original="$2"
            shift
            ;;
        '--overlay')
            overlays+=("$2")
            shift
            ;;
        '--table')
            case "$2" in
            'help')
                help_table
                return
                ;;
            'help='*)
                help_table
                "table_common_${2:5}"
                return
                ;;
            *)
                table="$2"
                shift
                ;;
            esac
            ;;
        '--mkfs-arg')
            mkfs_args["${2%%=*}"]="${2#*=}"
            shift
            ;;
        # Builder behaviour options
        '--async-child')
            async_child=1
            ;;
        '--keyring-helper')
            keyring_helper="$2" 
            shift
            ;;
        '--freeze-pacman-config')
            freeze_pacman_config=1
            ;;
        '--freeze-pacman-static')
            freeze_pacman_static=1
            ;;
        '--tmpfs-root')
            tmpfs_root_options='defaults'
            ;;
        '--tmpfs-root='*)
            tmpfs_root_options="${2:13}"
            ;;
        '--use-pacman-static')
            use_pacman_static=1
            ;;
        # Run-target options
        '--binfmt-check')
            run_binfmt_check=1
            ;;
        '--clean-builds')
            run_clean_builds=1
            ;;
        '--create')
            case "$2" in
            'help')
                help_create
                return
                ;;
            'help='*)
                help_create
                declare -fp "create_${2:5}"
                return
                ;;
            *)
                creates+=("$2")
                shift
                ;;
            esac
            ;;
        '--only-prepare-child')
            run_only_prepare_child=1
            ;;
        '--only-backup-keyring')
            run_only_backup_keyring=1
            ;;
        '--help')
            help_aimager
            return 0
            ;;
        *)
            if [[ "${log_enabled['error']}" ]]; then
                log_error "Unknown argument '$1'"
                report_wrong_arg './aimager.sh' "${args_original[*]}" "$@"
            fi
            bad_arg=1
            ;;
        esac
        shift
    done
    if (( "${bad_arg}" )); then
        return 1
    else
        aimager
    fi
}

aimager_init
aimager_cli "$@"
