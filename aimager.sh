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

# init shell options, and log macros
aimager_init() { 
    # e: error and exit on non-zero return
    # u: error if a varaible is not defined (unbound)
    # pipefail: error if not a whole pipe is successful
    set -euo pipefail
    # log macros expansion
    local log_common_start='echo -n "[${script_name}:'
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
    install_pkgs=()
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
    script_name=aimager.sh
    table=''
    tmpfs_root_options=''
    use_pacman_static=0
}

# check_executable $1 to $2, fail if it do not exist
check_executable() {
    eval "${log_debug}" || echo "Checking executable $1 (must exist)"
    local type_executable
    if ! type_executable=$(type -t "$1"); then
        eval "${log_error}" || echo \
            "Could not find needed executable \"$1\"."\
            "It's needed to $2."\
            "Refuse to continue."
        return 1
    fi
    if [[ "${type_executable}" != 'file' ]]; then
        eval "${log_error}" || echo \
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
    if (( "${use_pacman_static}" )) ||
        ! check_executable pacman 'install packages'
    then
        use_pacman_static=1
        update_and_use_pacman_static
    fi
    eval "${log_info}" || echo "Say hello to our hero Pacman O<. ."
    pacman --version
}

check_date_locale() {
    if [[ -z "${time_start_aimager}" ]]; then
        eval "${log_error}" || echo \
            "Start time was not recorded, please check your 'date' installation"
        return 1
    fi
    local actual_output="${LANG}$(LANG=C date -ud @0)"
    local expected_output='CThu Jan  1 00:00:00 UTC 1970'
    if [[ "${actual_output}" != "${expected_output}" ]]; then
        eval "${log_error}" || echo \
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
    eval "${log_info}" || echo "Downloading '$2' < '$1'"
    curl -qgb "" -fL --retry 3 --retry-delay 3 -o "$2".temp "$1"
    eval "${log_info}" || echo "Downloaded '$2' <= '$1'"
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
        eval "${log_error}" || echo \
            "Dumped filenames (${#filenames[@]}), names (${#names[@]}) and"\
            "versions (${#versions[@]}) length not equal to each other"
        eval "${log_debug}" || echo \
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
        eval "${log_error}" || echo \
            "Failed to get package '$5' of arch '$4' from repo '$2$3' at '$1'"
        return 1
    fi
    eval "${log_info}" || echo \
        "Latest '$5' of arch '$4' from repo '$2$3' at '$1'"\
        "is at version '${pkg_ver}'"
    pkg_filename="$2$3:$4:${filename}"
    pkg_path=cache/pkg/"${pkg_filename}"
    if [[ -f "${pkg_path}" ]]; then
        eval "${log_info}" || echo \
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
    eval "${log_info}" || echo \
        'Trying to update pacman-static from archlinuxcn repo'
    if touched_after_start cache/bin/pacman-static; then
        eval "${log_info}" || echo \
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
    eval "pacman() { '${pkg_dir}/usr/bin/pacman-static' "\$@"; }"
}

prepare_pacman_conf() {
    eval "${log_info}" || echo \
        "Preparing pacman configs from ${distro_stylised} repo"\
        "at '${repo_url_base}'"
    if (( "${freeze_pacman_config}" )) && [[ 
        -f "${path_etc}/pacman-strict.conf" && 
        -f "${path_etc}/pacman-loose.conf" ]]
    then
        eval "${log_info}" || echo \
            'Local pacman configs exist and --freeze-pacman was set'\
            'using existing configs'
        return
    elif touched_after_start "${path_etc}/pacman-strict.conf" &&
        touched_after_start "${path_etc}/pacman-loose.conf"
    then
        eval "${log_info}" || echo \
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
                eval "${log_error}" || echo \
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
        eval "${log_error}" || echo \
            "Core repo '${repo_core}' was not found in base repos:"\
            "${repos_base[*]}"
        return 1
    fi
    eval "${log_info}" || echo \
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
    eval "${log_info}" || echo \
        "Generated loose config at '${path_etc}/pacman-loose.conf' and "\
        "strict config at '${path_etc}/pacman-strict.conf'"
}

no_source() {
    eval "${log_fatal}" || echo \
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

table_mbr_header() {
    printf '%s:%s\n' \
        label mbr \
        sector-size 512 \

}

table_part() { #1 name, 2 start, 3 size, 4 type, 5 suffix
    echo -n "name=$1," # for mbr this does nothing, but we use it for marks
    if [[ "$2" ]]; then
        echo -n "start=$2,"
    fi
    echo "size=$3,type=$4$5"
}

table_common_mbr_1g_esp() {
    table_mbr_header
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

table_common_mbr_16g_root() {
    table_mbr_header
    table_part root '' 16G linux ',bootable'
}

table_common_mbr_1g_esp_16g_root_aarch64() {
    table_common_mbr_1g_esp
    table_part root '' 16G 
}

help_table() {
    local name prefix=table_common_ tables=()
    for name in $(declare -F); do
        if [[ "${name}" == "${prefix}"* && ${#name} -gt 13 ]]; then
            tables+=("=${name:13}")
        fi
    done
    eval "${log_info}" || echo "Available common tables: ${tables[@]}"
    return
}

board_x64_uefi() {
    distro='Arch Linux'
    arch_target='x86_64'
    bootloader='systemd-boot'
    if [[ -z "${table:-}" ]]; then
        table='=gpt_1g_esp_16g_root_x86_64'
    fi
    initrd_maker="${initrd_maker:-booster}"
    install_pkgs+=('linux')
}

board_x86_legacy() {
    distro='Arch Linux 32'
    arch_target='i686'
    bootloader='syslinux'
    if [[ -z "${table:-}" ]]; then
        table='=mbr_16g_root'
    fi
    initrd_maker="${initrd_maker:-booster}"
    install_pkgs+=('linux')
}

board_amlogic_s9xxx() {
    distro='Arch Linux ARM'
    arch_target='aarch64'
    bootloader='u-boot'
    if [[ -z "${table:-}" ]]; then
        table='=mbr_1g_esp_16g_root_aarch64'
    fi
    initrd_maker="${initrd_maker:-booster}"
}

board_orangepi_5_family() {
    distro='Arch Linux ARM'
    arch_target='aarch64'
    bootloader='u-boot'
    if [[ -z "${table:-}" ]]; then
        table='=gpt_1g_esp_16g_root_aarch64'
    fi
    add_repos+=('7Ji')
    initrd_maker="${initrd_maker:-booster}"
    install_pkgs+=('linux-aarch64-rockchip-joshua-git')
}

board_orangepi_5() {
    board_orangepi_5_family
}

board_orangepi_5_plus() {
    board_orangepi_5_family
}

board_orangepi_5_max() {
    board_orangepi_5_family
}

board_orangepi_5_pro() {
    board_orangepi_5_family
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
    eval "${log_info}" || echo "Available repos: ${repos[@]}"
    return
}

require_arch_target() { #1: who
    local architecture
    for architecture in "${@:2}"; do
        if [[ "${arch_target}" == "${architecture}" ]]; then
            return
        fi
    done
    eval "${log_error}" || echo \
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
            eval "${log_error}" || echo \
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
            eval "${log_error}" || echo \
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
    if ! eval "${log_info}"; then
        echo 'Supported distro and their supported target architectures:'
        echo 'Arch Linux (archlinux, arch): x86_64'
        echo 'Arch Linux 32 (archlinux32, arch32): i486, pentium4, i686'
        echo 'Arch Linux ARN (archlinuxarm, archarm, alarm): armv7h, aarch64'
        echo 'Loong Arch Linux (loongarchlinux, loongarch): '\
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
        eval "${log_error}" || echo \
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
        eval "${log_error}" || echo \
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
    eval "${log_info}" || echo "Build ID is '${build_id}'"
    path_build=cache/build."${build_id}"
    eval "${log_info}" || echo "Build folder is '${path_build}'"
    path_etc="${path_build}/etc"
    path_root="${path_build}/root"
    mkdir -p "${path_build}"/{bin,etc,root}
    eval "${log_info}" || echo "Root mountpoint is '${path_root}'"
}

configure_out() {
    if [[ -z "${out_prefix}" ]]; then
        out_prefix="out/${build_id}-"
        eval "${log_warn}" || echo \
            "Output prefix not set, generated as '${out_prefix}'"
    fi
    if [[ "${out_prefix}" == */* ]]; then
        eval "${log_info}" || echo \
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
            eval "${log_error}" || echo "Unknown suffix ${size: -1}"
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
    eval "${log_info}" || echo 'Configuring partition table...'
    case "${table}" in
    '@'*)
        eval "${log_info}" || echo \\
            "Reading sfdisk-dump-like from '${table:1}'..."
        table=$(<"${table:1}")
        ;;
    '='*)
        local table_func="${table:1}"
        eval "${log_info}" || echo "Using common table '${table_func}'" 
        local table_func="table_common_${table_func/-/_}"
        if [[ $(type -t "${table_func}") == function ]]; then
            table=$("${table_func}")
        else
            eval "${log_error}" || echo \
                "Common table '${table}' is not supported, pass --table help"\
                "to get a list of pre-defined common tabless"
            return 1
        fi
        ;;
    '')
        eval "${log_warn}" || echo \
            'Table not defined, please define it with --table'
            # return 1
        ;;
    esac
    if ! eval "${log_info}"; then
        echo "Using the following partition table:"
        echo "${table}"
    fi
    table_part_orders=()
    declare -gA table_part_names
    declare -gA table_part_infos
    declare -gA table_part_sizes
    declare -gA table_part_offsets
    declare -gA table_part_types
    local line part_order part_name part_info part_type
    while read line; do
        [[ "${line,,}" =~ ^name=[^,]*(boot|root|home|swap), ]] || continue
        part_name="${line:5}"
        part_name="${part_name%%,*}"
        if [[ "${part_name}" == '"'*'"' ]]; then
            part_name="${part_name:1:-1}"
        fi
        part_order="${part_name: -4}"
        part_order="${part_order,,}"
        if [[ " ${table_part_orders[*]} " == *" ${part_order} "* ]]; then
            eval "${log_error}" || echo \
                "Duplicated part definition for ${part_order}"
            return 1
        fi
        table_part_orders+=("${part_order}")
        part_info="${line#*,}"
        table_part_names["${part_order}"]="${part_name}"
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
        table_part_infos["${part_order}"]="${line#*,}"
    done <<< "${table}"
    if ! eval "${log_info}"; then
        echo "Parsed partition tables:"
        local i
        for i in "${!table_part_orders[@]}"; do
            part_order="${table_part_orders[$i]}"
            printf '%02d: %4s, name %16s, size %6dM, offset %6dM, type %36s\n' \
                "${i}" "${part_order}" \
                "\"${table_part_names["${part_order}"]}\"" \
                "${table_part_sizes["${part_order}"]}" \
                "${table_part_offsets["${part_order}"]}" \
                "\"${table_part_types["${part_order}"]}\"" \

        done
    fi
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
            # part_order="${table_part_orders[$i]}"
            part_end_this=$((
                "${table_part_sizes["${part_order}"]:-0}" +
                "${table_part_offsets["${part_order}"]:-"${part_end_last}"}"
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
    eval "${log_info}" || echo \
        "Table needs to be created on a disk with size at least ${table_size}M"
}

configure_pkgs() {
    local pkgs_allowed=()
    local pkg
    for pkg in "${install_pkgs[@]}"; do
        case "${pkg}" in
        'booster'|'mkinitcpio'|'dracut')
            eval "${log_warn}" || echo \
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
    eval "${log_info}" || echo \
        "Aimager check complete."\
        "$(( $(date +%s) - ${time_start_aimager} )) seconds has elasped since"\
        "aimager started at $(date -d @"${time_start_aimager}")"
}

binfmt_check() {
    if [[ "${arch_target}" == loong64 ]]; then
        local arch_target=loongarch64
    fi
    if [[ "${arch_host}" == "${arch_target}" ]]; then
        eval "${log_warn}" || echo \
            "Host architecture ${arch_host} =="\
            "target architecture ${arch_target},"\
            "no need nor use to run binfmt check"
    else
        local dir_aimager=$(readlink -f "$0")
        dir_aimager="${dir_aimager%/*}"
        eval "${log_warn}" || echo \
            "Host architecture ${arch_host} !="\
            "target architecture ${arch_target},"\
            "checking if we have binfmt ready"
        eval "${log_info}" || echo \
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
        eval "${log_error}" || echo \
            "Current context require us to run as root"\
            "but we are ${identity_name}"
        return 1
    fi
    if [[ "${identity_uid}" != '0' ]]; then
        eval "${log_error}" || echo \
            "Current context require us to run as root (UID = 0)"\
            "but we have UID ${identity_uid}"
        return 1
    fi
    if [[ "${identity_gid}" != '0' ]]; then
        eval "${log_error}" || echo \
            "Current context require us to run as root (GID = 0)"\
            "but we have GID ${identity_uid}"
        return 1
    fi
}

identity_require_non_root() {
    identity_get_name_uid_gid || return 1
    if [[ "${identity_name}" == 'root' ]]; then
        eval "${log_error}" || echo \
            'Current context require us to NOT run as root but we are root'
        return 1
    fi
    if [[ "${identity_uid}" == '0' ]]; then
        eval "${log_error}" || echo \
            'Current context require us to NOT run as root (UID != 0)'\
            'but we have UID 0'
        return 1
    fi
    if [[ "${identity_gid}" == '0' ]]; then
        eval "${log_error}" || echo \
            'Current context require us to NOT run as root (GID != 0)'\
            'but we have GID 0'
        return 1
    fi
}

identity_require_mapped_root() {
    identity_require_root || return 1
    eval "${log_info}" || echo \
        'Trying to write content under /sys to check whether we were'\
        'mapped to root or are real root.'\
        'Expecting a write failure...'
    if echo test > /sys/sys_write_test; then
        eval "${log_error}" || echo \
            'We can write to /sys which means we have real root permission,'\
            'refuse to continue as real root'
        return 1
    else
        eval "${log_info}" || echo \
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
            eval "${log_error}" || echo \
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
        eval "${log_error}" || echo \
            "Recorded subuid range in /etc/subuid too short"\
            "(${identity_subuid_range} < 65535)"
        exit 1
    fi
    identity_subuid_start="${identity_subid%:*}"
    identity_get_subid gid
    identity_subgid_range="${identity_subid#*:}"
    if [[ "${identity_subgid_range}" -lt 65535 ]]; then
        eval "${log_error}" || echo \
            "Recorded subgid range in /etc/subgid too short"\
            "(${identity_subgid_range} < 65535)"
        exit 1
    fi
    identity_subgid_start="${identity_subid%:*}"
}

child_wait() {
    eval "${log_debug}" || echo \
        "Child $$ started and waiting for parent to map us..."
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
        eval "${log_error}" || echo \
            'Give up after waiting for 10 seconds yet parents fail to map us'
        return 1
    fi
    eval "${log_debug}" || echo 'Child wait complete'
}

child_fs() {
    eval "${log_info}" || echo 'Handling child rootfs...'
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
    if ! eval "${log_debug}"; then
        echo 'Child rootfs mountinfo is as follows:'
        local prefix_mount=$(readlink -f "${path_root}")
        grep '^\([0-9]\+ \)\{2\}[0-9]\+:[0-9]\+ [^ ]\+ '"${prefix_mount}" \
            /proc/self/mountinfo
    fi
}

child_check_binfmt() {
    if (( "${arch_cross}" )); then
        eval "${log_info}" || echo \
            "Entering chroot to run the minimum executeble 'true' to check if"\
            "QEMU binfmt works properly"
        chroot "${path_root}" true
    fi
}

child_init_reuse() {
    eval "${log_info}" || echo "Reusing root tar ${reuse_root_tar}"
    bsdtar --acls --xattrs -xpf "${reuse_root_tar}" -C "${path_root}"
    child_check_binfmt
}

child_init_keyring() {
    if [[ ! -f "${keyring_archive}" ]]; then
        local path_chroot="${path_root}"
        if [[ "${keyring_helper}" ]]; then
            eval "${log_info}" || echo \
                "Borrowing keyring manager from root archive"\
                "'${keyring_helper}' to sub /mnt ..."
            if [[ ! -f "${keyring_helper}" ]]; then
                eval "${log_error}" || echo \
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
            eval "${log_warn}" || echo \
                "Initializing and populating keyring '${keyring_id}' for the"\
                "first time cross-architecture (from arch '${arch_host}' to"\
                "arch '${arch_target}') using target keyring managers. This"\
                "might take a very long time as gpg and its calculation for"\
                "encryption/decryption/hashing needs to be handled by QEMU."\
                "To speed this up consider pass --keyring-helper to borrow"\
                "keyring managers from a previously created rootfs archive for"\
                "the native architecture (yours is '${arch_host}')."
        fi
        eval "${log_info}" || echo \
            "Initializing keyring '${keyring_id}' for the first time..."
        chroot "${path_chroot}" pacman-key --init
        eval "${log_info}" || echo \
            "Populating keyring '${keyring_id}' for the first time..."
        chroot "${path_chroot}" pacman-key --populate
    fi
    mkdir -p cache/keyring
    eval "${log_info}" || echo \
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
    eval "${log_info}" || echo "Keyring ID is ${keyring_id}"
    local keyring_archive=cache/keyring/"${keyring_id}".tar
    local path_keyring="${path_root}/etc/pacman.d/gnupg"
    if [[ -f "${keyring_archive}" ]]; then
        eval "${log_info}" || echo \
            "Reusing keyring backup archive '${keyring_archive}'..."
        mkdir -p "${path_keyring}"
        bsdtar --acls --xattrs -xpf "${keyring_archive}" -C "${path_keyring}"
    else
        eval "${log_warn}" || echo \
            "This seems our first attempt to install for ${keyring_id},"\
            "need to initialize the keyring..."
        child_init_keyring
    fi
    eval "${log_info}" || echo "Going back to verify bootstrap packages..."
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
    eval "${log_fatal}" || echo 'Not implemented yet'
    return 1
}

child_setup_initrd_maker() {
    eval "${log_info}" || echo \
        'Checking if we need to install and hack initrd maker...'
    if pacman -T --config "${path_etc}/pacman-strict.conf" initramfs \
        > /dev/null
    then
        return
    fi
    if [[ "${initrd_maker}" ]]; then
        eval "${log_info}" || echo "Installing initrd maker ${initrd_maker}..."
        pacman -S --config "${path_etc}/pacman-strict.conf" --noconfirm \
            "${initrd_maker}"
    else
        eval "${log_warn}" || echo \
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
        eval "${log_error}" || echo \
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

child_setup() {
    local overlay
    for overlay in "${overlays[@]}"; do
        bsdtar --acls --xattrs -xpf "${overlay}" -C "${path_root}"
    done
    child_setup_initrd_maker
    if (( "${#install_pkgs[@]}" )); then
        eval "${log_info}" || echo \
            "Installing the following packages: ${install_pkgs[*]}"
        pacman -S --config "${path_etc}/pacman-strict.conf" --noconfirm \
            --needed "${install_pkgs[@]}"
    fi
    child_revert_initrd_maker
    if [[ "${pacman_conf_append}" ]]; then
        echo "${pacman_conf_append}" >> "${path_root}/etc/pacman.conf"
    fi
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
    eval "${log_info}" || echo 'Child cleaning...'
    eval "${log_info}" || echo 'Killing child gpg-agent...'
    chroot "${path_root}" pkill -SIGINT --echo '^gpg-agent$' || true
    if [[ "${tmpfs_root_options}" ]]; then
        eval "${log_info}" || echo 'Using tmpfs, skipped cleaning'
        return
    fi
    eval "${log_info}" || echo 'Syncing after killing gpg-agent...'
    sync
    eval "${log_info}" || echo 'Umounting rootfs...'
    umount -R "${path_root}"
    eval "${log_info}" || echo 'Deleting rootfs leftovers...'
    rm -rf "${path_root}"
}

child() {
    child_wait
    if (( "${run_clean_builds}" )); then
        eval "${log_info}" || echo 'Cleaning builds...'
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
    eval "${log_info}" || echo 'Child exiting!!'
}

prepare_child_context() {
    {
        echo 'set -euo pipefail'
        declare -p | grep 'declare -[-fFgIpaAilnrtux]\+ [a-z_]'
        declare -f
        echo 'script_name=child.sh'
        echo 'child'
    } >  "${path_build}/bin/child.sh"
}

run_child_and_wait_sync() {
    eval "${log_info}" || echo \
        'System unshare support --map-users and --map-groups,'\
        'using unshare itself to map'
    eval "${log_info}" || echo 'Spwaning child (sync)...'
    unshare --user --pid --mount --fork \
        --map-root-user \
        --map-users="${map_users}" \
        --map-groups="${map_groups}" \
        -- \
        /bin/bash "${path_build}/bin/child.sh"
}

run_child_and_wait_async() {
    eval "${log_info}" || echo \
        'System unshare does not support --map-users and --map-groups,'\
        'mapping manually using newuidmap and newgidmap'
    eval "${log_info}" || echo 'Spwaning child (async)...'
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
    eval "${log_info}" || echo \
        "Mapped UIDs and GIDs for child ${pid_child}, "\
        "waiting for it to finish..."
    wait "${pid_child}"
    trap - INT TERM EXIT
    eval "${log_info}" || echo "Child ${pid_child} finished successfully"
}

run_child_and_wait() {
    if (( "${async_child}" )); then
        eval "${log_warn}" || echo 'Forcing to spwan child in async way'
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
    eval "${log_info}" || echo 'Cleaning up before exiting...'
    rm -rf "${path_build}"
}

work() {
    eval "${log_info}" || echo \
        "Building for distro '${distro}' to architecture '${arch_target}'"\
        "from architecture '${arch_host}'"
    prepare_pacman_conf
    prepare_child_context
    if (( "${run_only_prepare_child}" )); then
        eval "${log_info}" || echo 'Early exiting before spawning child ...'
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
    eval "${log_info}" || echo 'aimager exiting!!'
}

create_part_boot_img() {
    if [[ "${created['part-boot.img']:-}" ]]; then
        return
    fi
    local path_out="${out_prefix}part-boot.img"
    eval "${log_info}" || echo "Creating boot partition image '${path_out}'..."
    truncate -s "${table_part_sizes[boot]}"M "${path_out}.temp"
    mkfs.fat ${mkfs_args[boot]:-} "${path_out}.temp"
    mcopy -osi "${path_out}.temp" "${path_root}/boot/"* ::
    mv "${path_out}"{.temp,}
    created['part-boot.img']='y'
    eval "${log_info}" || echo "Created boot partition image '${path_out}'"
}

create_part_root_img() {
    if [[ "${created['part-root.img']:-}" ]]; then
        return
    fi
    local path_out="${out_prefix}part-root.img"
    eval "${log_info}" || echo "Creating root partition image '${path_out}'..."
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
    mkfs.ext4 -d "${path_root}" ${mkfs_args[root]:-} "${path_out}.temp"
    for shadow in "${shadows[@]}"; do
        umount "${path_root}/${shadow}"
    done
    mv "${path_out}"{.temp,}
    created['part-root.img']='y'
    eval "${log_info}" || echo "Created root partition image '${path_out}'"
}

create_part_home_img() {
    if [[ "${created['part-home.img']:-}" ]]; then
        return
    fi
    local path_out="${out_prefix}part-home.img"
    eval "${log_info}" || echo "Creating home partition image '${path_out}'..."
    truncate -s "${table_part_sizes[home]}"M "${path_out}.temp"
    mkfs.ext4 -d "${path_root}/home" ${mkfs_args[home]:-} "${path_out}.temp"
    mv "${path_out}"{.temp,}
    created['part-home.img']='y'
    eval "${log_info}" || echo "Created home partition image '${path_out}'"
}

create_root_tar() {
    if [[ "${created['root.tar']:-}" ]]; then
        return
    fi
    local path_out="${out_prefix}root.tar"
    eval "${log_info}" || echo "Creating root archive '${path_out}'..."
    bsdtar --acls --xattrs -cpf "${path_out}.temp" -C "${path_root}" \
        --exclude './dev' --exclude './mnt' --exclude './proc' \
        --exclude './sys' --exclude './etc/pacman.d/gnupg/S.*' \
        .
    mv "${path_out}"{.temp,}
    created['root.tar']='y'
    eval "${log_info}" || echo "Created root archive '${path_out}'"
}

create_keyring_helper_tar() {
    if [[ "${created['keyring-helper.tar']:-}" ]]; then
        return
    fi
    local path_out="${out_prefix}keyring-helper.tar"
    eval "${log_info}" || echo "Creating keyring helper '${path_out}'..."
    local filters=(
        --include './bin' --include './etc/pacman*' --include './lib*'
        --include './usr/bin' --include './usr/lib/getconf'
        --include './usr/lib/*.so*' --include './usr/share/makepkg'
        --exclude './etc/pacman.d/gnupg/*'
    )
    if [[ "${created['root.tar']:-}" ]]; then
        eval "${log_info}" || echo 'Reusing root.tar created in the same run...'
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
    eval "${log_info}" || echo "Created keyring helper '${path_out}'"
}

create_disk_img() {
    :
}

help_create() {
    local name prefix=create_ creates=()
    for name in $(declare -F); do
        if [[ "${name}" == "${prefix}"* && ${#name} -gt 7 ]]; then
            creates+=("${name:7}")
        fi
    done
    eval "${log_info}" || echo \
        "Available to-be-created targets (_ can be written as either - or .):"\
        "${creates[*]}"
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
        'board [board]' 'board, would call corresponding built-in board definition to define other options, pass "help" to get the list of supported boards, pass "help=[board]" to get the board definition; default: none' \
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
        'mkfs-arg [part]=[arg]' 'addtional args passed when creating fs, part could be boot, home, root, swap'\
        'overlay [overlay]' 'path of overlay (a tar file), extracted to the target image after all other configuration is done, can be specified multiple-times' \
        'table [table]' 'either sfdisk-dump-like multi-line string, or @[path] to read such string from, or =[name] to use one of the built-in common tables, e.g. --table @mytable.sdisk.dump, --table =mbr_16g_root. pass "help" to check the list of built-in common tables. pass "help=[common table]" to show the built-in definition. note that for both mbr and gpt the name property for each partition is always needed and would be used by aimager to find certain partitions (boot ends with boot, root ends with root, swap ends with swap, home ends with home, all case-insensitive), even if that has no actual use on mbr tables' \

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
        '--mkfs-arg')
            mkfs_args["${2%%=*}"]="${2#*=}"
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
            if ! eval "${log_error}"; then
                echo "Unknown argument '$1'"
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
