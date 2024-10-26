#!/bin/bash -e

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

## Part 0: coding guidelines
### naming scheme: All native Bash variables and functions follow snake_case. All environment variables follow SCREAM_CASE. No camelCase, no PascalCase
### variable scope: Prefer local variables. If a global vairable would be defined, comment before function body; if a outer variable would be used (and possibly re-defined locally) then comment before function body
### variable expansion: Expand all user-defined variables and long-name Bash built-in variable like ${varname}, expand single character Bash built-in variable like $* 
### exception handle: The builder always run with -e, so all non-zero returns should be handled, unless the script should break on purpose
### dependency introduction: Always prefer Bash-native ways to handle things, try to introduce as few external program dependencies as possible. If there really are, prefer to use those provided in coreutils, than those other that come pre-installed on Arch / Ubuntu, than those that need to be installed manually
### quoting: Prefer single quote. Use double quote only when: variables need to be expanded, or single quote need to be included. If possible, shorten double-quote usage by using C-style string catenation, e.g. 'Your name is '"${name}"', welcome!' => 'Your name is Example Name, welcome!'


## Part 1: data structure declaration

# structure: repo config
## raw: raw repo config
### name: raw_repo_config(_[name]) raw_repo_configs
### format: [name];[line];[line]
### example: raw_repo_config_7Ji='7Ji;SigLevel=Never;Server=https://github.com/7Ji/archrepo/releases/download/$arch'

## expanded: expaned repo config
### name: expaned_repo_condfig(_[name]) expanded_repo_config
### format:

## name: repo_config


## Part 2: function declaration
### Function rules:
### - snake_case_only, and as declarative as possible
### - no 'function ' prefix for declaration
### - only declare local variables, if outer logic needs to pre-declare variables, comment about it

# Logging statements, currently always printing to stderr
## $1: level
## $2: func name
## $3: line no
## $4...: formatted content
# log() {
#     printf -- '[%s] %s@%s: %s\n' "$1" "$2" "$3" "${*:4}"
# }

# pre-defined various logging statements
## Callers shall log like this: eval "${log_info}" || echo 'Log content'
## When a logging level is enabled the above is effectively echo -n  '[INFO] function_name@line_no: ' && false ||  echo 'Log content'
## When a logging level is disabled the above is effectively true ||  echo 'Log content' so echo would be skipped
## For more info, read https://7ji.github.io/scripting/2024/09/29/bash-logging-with-funcname-lineno.html
log_common_start='echo -n "['
log_common_end='] ${FUNCNAME}@${LINENO}: " && false'
log_info="${log_common_start}INFO${log_common_end}"
log_warn="${log_common_start}WARN${log_common_end}"
log_error="${log_common_start}ERROR${log_common_end}"
log_fatal="${log_common_start}FATAL${log_common_end}"

# Debugging-only definitions
if [[ "${AIMAGER_DEBUG}" ]]; then
log_debug="${log_common_start}DEBUG${log_common_end}"

# Assert variables are defined and non-empty
## $1: caller (for logging)
## $2...: vairable names
assert_declared() {
    eval "${log_debug}" || echo "Asserting variables for $1: ${*:2}"
    local _bad= _var=
    while (( $# > 1 )); do
        if [[ ! -v $2 ]]; then
            eval "${log_fatal}" || echo "Variable \"$2\" is not declared"
            _bad='y'
            shift
            continue
        fi
        declare -n _var="$2"
        if [[ -z "${_var}" ]]; then
            eval "${log_fatal}" || echo "Variable \"$2\" is empty"
            _bad='y'
        fi
        shift
    done
    if [[ "${_bad}" ]]; then
        eval "${log_fatal}" || echo 'Declaration assertion failed'
        exit 1
    fi
}
assert_declared_this_func='assert_declared "${FUNCNAME}@${LINENO}" '
else # Empty function bodies and short paths when debugging is not enabled,
log_debug='true'
assert_declared() { :; }
assert_declared_this_func="false"
fi

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
    check_executable "$1" "$2" 'false'
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
    if [[ -f cache/bin/pacman && -z "${freeze_pacman}" ]] ; then
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
    configure_archlinuxcn
    get_repo_pkg_file "${mirror_archlinuxcn}" archlinuxcn "${architecture_host}" pacman-static usr/bin/pacman-static
    mkdir -p cache/bin
    ln -sf "../pkg/${pkg_dir_path#cache/pkg/}/usr/bin/pacman-static" cache/bin/pacman
}

prepare_pacman_conf() {
    eval "${log_info}" || echo "Preparing pacman configs from ${distribution_stylised} repo at '${repo_url_base}'"
    if touched_after_start cache/etc/pacman-strict.conf &&
        touched_after_start cache/etc/pacman-loose.conf
    then
        eval "${log_info}" || echo 'Local pacman configs were already updated during this run, no need to update'
        return
    fi
    get_repo_pkg_file "${repo_url_base}" "${repo_core}" "${architecture_target}" pacman etc/pacman.conf
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
    eval "${log_info}" || echo "Distribution ${distribution_stylised} has the following base repos: ${repos_base[@]}"
    local config_head=$(
        echo '[options]'
        printf '%-13s= %s\n' \
            'RootDir' 'cache/root' \
            'DBPath' 'cache/root/var/lib/pacman/' \
            'CacheDir' 'cache/pkg/'"${distribution_safe}:${architecture_target}" \
            'LogFile' 'cache/root/var/log/pacman.log' \
            'GPGDir' 'cache/root/etc/pacman.d/gnupg' \
            'HookDir' 'cache/root/etc/pacman.d/hooks' \
            'Architecture' "${architecture_target}"
    )
    local config_tail=$(printf '[%s]\nServer = '"${repo_url_base}"'\n' "${repos_base[@]}")
    printf '%s\n%-13s= %s\n%s' "${config_head}" 'SigLevel' 'Never' "${config_tail}" > cache/etc/pacman-loose.conf
    printf '%s\n%-13s= %s\n%s' "${config_head}" 'SigLevel' 'DatabaseOptional' "${config_tail}" > cache/etc/pacman-strict.conf
    eval "${log_info}" || echo "Generated loose config at 'cache/etc/pacman-loose.conf' and strict config at 'cache/etc/pacman-strict.conf'"
}

assert_errexit() {
    if [[ $- != *e* ]]; then
        eval "${log_fatal}" || echo 'The script must be run with -e'
        exit 1
    fi
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
    distribution='Arch Linux'
    architecture_target='x86_64'
    bootloader='systemd-boot'
}

board_x86_legacy() {
    distribution='Arch Linux 32'
    architecture_target='i686'
    bootloader='syslinux'
}

_board_orangepi_5_family() {
    distribution='Arch Linux ARM'
    architecture_target='aarch64'
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

guard_configure='declare -n guard="configured_${FUNCNAME#configure_}" && [[ "${guard}" ]] && return || guard=1'

configure_archlinuxcn() {
    eval "${guard_configure}"
    if [[ "${repo_url_parent}" ]]; then
        mirror_archlinuxcn="${repo_url_parent}/archlinuxcn/"'$arch'
    else
        mirror_archlinuxcn='https://repo.archlinuxcn.org/$arch'
    fi
}

require_architecture_target() {
    local architecture
    for architecture in "$@"; do
        if [[ "${architecture_target}" == "${architecture}" ]]; then
            return
        fi
    done
    eval "${log_error}" || echo "${distribution_stylised} requires target architecture to be one of $@, but it is ${architecture_target}"
    return 1
}

_distribution_common() {
    repo_core="${repo_core:-core}"
}

distribution_archlinux() {
    distribution_stylised='Arch Linux'
    distribution_safe='archlinux'
    require_architecture_target x86_64
    _distribution_common
    if [[ -z "${repo_url_archlinux}" ]]; then
        local mirror_arch_suffix='$repo/os/$arch'
        if [[ "${repo_url_parent}" ]]; then
            repo_url_archlinux="${repo_url_parent}/archlinux/${mirror_arch_suffix}"
        else
            repo_url_archlinux="https://geo.mirror.pkgbuild.com/${mirror_arch_suffix}"
        fi
    fi
    declare -gn repo_url_base=repo_url_archlinux
}

distribution_archlinux32() {
    distribution_stylised='Arch Linux 32'
    distribution_safe='archlinux32'
    require_architecture_target i486 pentium4 i686
    _distribution_common
    if [[ -z "${repo_url_archlinux32}" ]]; then
        if [[ "${repo_url_parent}" ]]; then
            repo_url_archlinux32="${repo_url_parent}"'/archlinux32/$arch/$repo'
        else
            eval "${log_error}" || echo 'Arch Linux 32 does not have a globally GeoIP-based mirror and a local mirror must be defined through either --repo-url-archlinux32 or --repo-url-parent. Please choose one from https://www.archlinux32.org/download or use your own local mirror.'
            return 1
        fi
    fi
    declare -gn repo_url_base=repo_url_archlinux32
}

distribution_archlinuxarm() {
    distribution_stylised='Arch Linux ARM'
    distribution_safe='archlinuxarm'
    require_architecture_target aarch64 armv7h
    _distribution_common
    if [[ -z "${repo_url_archlinuxarm}" ]]; then
        local mirror_alarm_suffix='$arch/$repo'
        if [[ "${repo_url_parent}" ]]; then
            repo_url_archlinuxarm="${repo_url_parent}/archlinuxarm/${mirror_alarm_suffix}"
        else
            repo_url_archlinuxarm='http://mirror.archlinuxarm.org/'"${mirror_alarm_suffix}"
        fi
    fi
    declare -gn repo_url_base=repo_url_archlinuxarm
}

distribution_loongarchlinux() {
    distribution_stylised='Loong Arch Linux'
    distribution_safe='loongarchlinux'
    require_architecture_target loong64
    _distribution_common
    if [[ -z "${repo_url_loongarchlinux}" ]]; then
        if [[ "${repo_url_parent}" ]]; then
            repo_url_loongarchlinux="${repo_url_parent}"'/loongarch/archlinux/$repo/os/$arch'
        else
            eval "${log_error}" || echo 'Loong Arch Linux does not have a globally GeoIP-based mirror and a local mirror must be defined through either --repo-url-loongarchlinux or --repo-url-parent. Please choose one from https://loongarchlinux.org/pages/download or use your own local mirror.'
            return 1
        fi
    fi
    declare -gn repo_url_base=repo_url_loongarchlinux
}

distribution_archriscv() {
    distribution_stylised='Arch Linux RISC-V'
    distribution_safe='archriscv'
    require_architecture_target riscv64
    _distribution_common
    if [[ -z "${repo_url_archriscv}" ]]; then
        if [[ "${repo_url_parent}" ]]; then
            repo_url_archriscv="${repo_url_parent}"'/archriscv/repo/$repo'
        else
            repo_url_archriscv='https://riscv.mirror.pkgbuild.com/repo/$repo'
        fi
    fi
    declare -gn repo_url_base=repo_url_archriscv
}

help_distribution() {
    eval "${log_info}" || echo 'Supported distribution and their supported target architectures:'
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

aimager_configure() {
    export PATH="${PWD}/cache/bin:${PATH}" LANG=C
    time_start_aimager=$(date +%s) || time_start_aimager=''
    local board_func="board_${board/-/_}"
    if [[ $(type -t "${board_func}") == function ]]; then
        "${board_func}"
    else
        eval "${log_error}" || echo "Board '${board}' is not supported, pass --board help to get a list of supported boards"
        return 1
    fi
    case "${distribution}" in
    'Arch Linux'|'archlinux'|'arch')
        distribution_archlinux
        ;;
    'Arch Linux 32'|'archlinux32'|'arch32')
        distribution_archlinux32
        ;;
    'Arch Linux ARM'|'archlinuxarm'|'archarm'|'alarm')
        distribution_archlinuxarm
        ;;
    'Loong Arch Linux'|'loongarchlinux'|'loongarch')
        distribution_loongarchlinux
        ;;
    'Arch Linux RISC-V'|'archlinuxriscv'|'archriscv')
        distribution_archriscv
        ;;
    *)
        eval "${log_error}" || echo "Unsupported distribution '${distribution}', use --disto help to check the list of supported distributions"
        return 1
        ;;
    esac
    if [[ -z "${out_prefix}" ]]; then
        out_prefix="out/${distribution_safe}-${architecture_target}-${board}-$(date +%Y%m%d%H%M%S)-"
        eval "${log_warn}" || echo "Output prefix not set, generated as '${out_prefix}'"
        if [[ "${out_prefix}" == */* ]]; then
            eval "${log_info}" || echo "Output prefix contains folder, pre-creating it..."
            mkdir -p "${out_prefix%/*}"
        fi
    fi
    out_root_tar="${out_prefix}root.tar"
}

aimager_check() {
    check_executables
    check_date_locale
    eval "${log_info}" || echo "Aimager check complete. $(( $(date +%s) - ${time_start_aimager} )) seconds has elasped since aimager started at $(date -d @"${time_start_aimager}")"
}

binfmt_check() {
    if [[ "${architecture_target}" == loong64 ]]; then
        local architecture_target=loongarch64
    fi
    if [[ "${architecture_host}" != "${architecture_target}" ]]; then
        eval "${log_warn}" || echo "Host architecture ${architecture_host} != target architecture ${architecture_target}, checking if we have binfmt ready"
        eval "${log_info}" || echo "Running the following test command: 'sh -c \"cd test/binfmt; ./test.sh ${architecture_target}\"'"
        sh -c 'cd test/binfmt; ./test.sh '"${architecture_target}"
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
    rm -rf cache/root
    mkdir -p cache/root/{boot,dev,etc/pacman.d,proc,run,sys,tmp,var/{cache/pacman/pkg,lib/pacman,log}}
    mount cache/root cache/root -o bind
    mount tmpfs-dev cache/root/dev -t tmpfs -o mode=0755,nosuid
    mount tmpfs-sys cache/root/sys -t tmpfs -o mode=0755,nosuid
    mkdir -p cache/root/{dev/{shm,pts},sys/module}
    chmod 1777 cache/root/{dev/shm,tmp}
    chmod 555 cache/root/{proc,sys}
    mount proc cache/root/proc -t proc -o nosuid,noexec,nodev
    mount devpts cache/root/dev/pts -t devpts -o mode=0620,gid=5,nosuid,noexec
    local node
    for node in full null random tty urandom zero; do
        devnode=cache/root/dev/"${node}"
        touch "${devnode}"
        mount /dev/"${node}" "${devnode}" -o bind
    done
    ln -s /proc/self/fd/2 cache/root/dev/stderr
    ln -s /proc/self/fd/1 cache/root/dev/stdout
    ln -s /proc/self/fd/0 cache/root/dev/stdin
    ln -s /proc/kcore cache/root/dev/core
    ln -s /proc/self/fd cache/root/dev/fd
    ln -s pts/ptmx cache/root/dev/ptmx
    ln -s $(readlink -f /dev/stdout) cache/root/dev/console
}

child_clean() {
    rm -rf cache/root/dev/* cache/sys/*
}

child() {
    child_wait
    child_fs
    if [[ "${reuse_root_tar}" ]]; then
        eval "${log_info}" || echo "Reusing root tar ${reuse_root_tar}"
        bsdtar --acls --xattrs -xpf "${reuse_root_tar}" -C cache/root
    else
        pacman -Sy --config cache/etc/pacman-loose.conf --noconfirm base
    fi
    eval "${log_info}" || echo "Creating root archive to '${out_root_tar}'..."
    bsdtar --acls --xattrs -cpf "${out_root_tar}.temp" -C cache/root --exclude ./dev --exclude ./proc --exclude ./sys .
    mv "${out_root_tar}"{.temp,}
    eval "${log_info}" || echo 'Child exiting!!'
}

prepare_child_context() {
    {
        declare -p | grep 'declare -[-fFgIpaAilnrtux]\+ [a-z_]'
        declare -f
        echo 'child'
    } >  cache/child.sh
}

run_child_and_wait() {
    local unshare_fields=$(unshare --help | sed 's/^ \+--map-users=\(.\+\)$/\1/p' -n)
    # Just why do they change the CLI so frequently?
    case "${unshare_fields}" in
    '<inneruid>:<outeruid>:<count>') # 2.40, Arch
        local map_users="1:${identity_subuid_start}:${identity_subuid_range}"
        local map_groups="1:${identity_subgid_start}:${identity_subgid_range}"
        ;;
    '<outeruid>,<inneruid>,<count>') # 2.38, Debian 12
        local map_users="${identity_subuid_start},1,${identity_subuid_range}"
        local map_groups="${identity_subgid_start},1,${identity_subgid_range}"
        ;;
    *) # <= 2.37, e.g. 2.37, Ubuntu 22.04, used on Github Actions
        eval "${log_info}" || echo 'System unshare does not support --map-users and --map-groups, mapping by ourselvee using newuidmap and newgidmap'
        eval "${log_info}" || echo 'Spwaning child (async)...'
        unshare --user --pid --mount --fork \
            /bin/bash -e cache/child.sh  &
        pid_child="$!"
        sleep 1
        newuidmap "${pid_child}" 0 "${identity_uid}" 1 1 "${identity_subuid_start}" "${identity_subuid_range}"
        newgidmap "${pid_child}" 0 "${identity_gid}" 1 1 "${identity_subgid_start}" "${identity_subgid_range}"
        eval "${log_info}" || echo "Mapped UIDs and GIDs for child ${pid_child}, waiting for it to finish..."
        wait "${pid_child}"
        eval "${log_info}" || echo "Child ${pid_child} finished successfully"
        return
        ;;
    esac
    eval "${log_info}" || echo 'System unshare support --map-users and --map-groups, using unshare itself to map'
    eval "${log_info}" || echo 'Spwaning child (sync)...'
    unshare --user --pid --mount --fork \
        --map-root-user \
        --map-users="${map_users}" \
        --map-groups="${map_groups}" \
        -- \
        /bin/bash -e cache/child.sh
}

aimager_work() {
    eval "${log_info}" || echo "Building for distribution '${distribution}' to architecture '${architecture_target}' from architecture '${architecture_host}'"
    prepare_pacman_conf
    prepare_child_context
    identity_get_subids
    run_child_and_wait
}

aimager() {
    identity_require_non_root
    aimager_configure
    if  [[ "${run_binfmt_check}" ]]; then
        binfmt_check
        return
    fi
    aimager_check
    aimager_work
}

help_aimager() {
    echo 'Usage:'
    echo "  $0 (--arch-host [arch]) (--arch-target [arch]) (--binfmt-check) (--board [board]) (--distro [distro]) (--freeze-pacman) (--mirror-local [parent]) (--help) (--initrd-maker [maker]) (--out-prefix [prefix]) (--pkg [pkg]) (--repo-add [repo]) (--repo-core [repo]) (--reuse-root-tar [tar])"
    echo
    printf -- '--%-25s %s\n' \
        'arch-host [arch]' 'overwrite the auto-detected host architecture; default: result of "uname -m"' \
        'arch-target [arch]' 'specify the target architecure; default: result of "uname -m"' \
        'binfmt-check' 'run a binfmt check for the target architecture after configuring and early quit' \
        'board [board]' 'specify a board name, which would optionally define --arch-target, --distro and other options, pass a special value "none" to define nothing, pass a special value "help" to get a list of supported boards; default: none' \
        'distro [distro]' 'specify the target distribution, pass a special value "help" to get a list of supported distributions' \
        'freeze-pacman' 'for hosts that do not have system-provided pacman, do not update pacman-static online if we already downloaded it previously' \
        'help' 'print this help message' \
        'initrd-maker' 'the initrd/initcpio/initramfs maker; supported: mkinitcpio, booster; default: booster (the traditional mkinitcpio would take too much time if you build cross-architecture)' \
        'out-prefix [prefix]' 'the prefix of output archives and images, by default this is out/[distro]-[arch]-[board]-YYYYMMDD-' \
        'pkg [pkg]' 'install the specified package into the target image, can be specified multiple times, default: base' \
        'repo-core [repo]' 'the name of the distro core repo, this is used to dump etc/pacman.conf from the pacman package; default: core' \
        'repo-define-[name] [url]' 'define a new repo which could be referenced in later logics' \
        'repo-url-parent [parent]' 'the URL parent of repos, usually public mirror sites fast and close to the builder, used to generate the whole repo URL, if this is not set then global mirror URL would be used if that repo has defined such, some repos need always this to be set as they do not provide a global URL, note this has no effect on the pacman.conf in final image but only for building; default: [none]; e.g.: https://mirrors.mit.edu' \
        'repo-url-[name] [url]' 'specify the full URL for a certain repo, should be in the format used in pacman.conf Server= definition, if this is not set for a repo then it would fall back to --repo-url-parent logic (see above), for third-party repos the name is exactly its name and for offiical repos the name is exactly the undercased distro name (first name in bracket in --distro help), note this has no effect on the pacman.conf in final image but only for building; default: [none]; e.g.: --repo-url-archlinux '"'"'https://mirrors.xtom.com/archlinux/$repo/os/$arch/'"'" \
        'repos-base [repo]' 'comma seperated list of base repos, order matters, if this is not set then it is generated from the pacman package dumped from core repo, as the upstream list might change please only set this when you really want a different list from upstream such as when you want to enable a testing repo, e.g., core-testing,core,extra-testing,extra,multilib-testing,multilib default: [none]' \
        'reuse-root-tar [tar]' 'reuse a tar to skip root bootstrapping and package installation, only board-specific operation would be performed' \

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
    architecture_host=$(uname -m)
    architecture_target=$(uname -m)
    board=none
    out_prefix=''
    run_binfmt_check=''
    repos_base=()
    reuse_root_tar=''
    local args_original="$@"
    while (( $# > 0 )); do
        case "$1" in
        '--arch-host')
            architecture_host="$2"
            shift
            ;;
        '--arch-target')
            architecture_target="$2"
            shift
            ;;
        '--board')
            if [[ "$2" == 'help' ]]; then
                help_board
                return
            fi
            board="$2"
            shift
            ;;
        '--binfmt-check')
            run_binfmt_check='yes'
            ;;
        '--distro')
            if [[ "$2" == 'help' ]]; then
                help_distribution
                return
            fi
            distribution="$2"
            shift
            ;;
        '--freeze-pacman')
            freeze_pacman='yes'
            ;;
        '--help')
            help_aimager
            return 0
            ;;
        '--inird-maker')
            initrd_maker="$2"
            shift
            ;;
        '--out-prefix')
            out_prefix="$2"
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
            declare -g "repo_url_${1:11}=$2"
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

assert_errexit

aimager_cli "$@"
