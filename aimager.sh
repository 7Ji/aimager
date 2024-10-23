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
    check_executable_must_exist curl 'download files from Internet'
    check_executable_must_exist date 'check current time'
    check_executable_must_exist install 'install file to certain paths'
    check_executable_must_exist sed 'do text substitution'
    check_executable_must_exist stat 'get file modification date'
    check_executable_must_exist tar 'extract file from archives'
    check_executable_must_exist uname 'dump machine architecture'
    check_executable_must_exist unshare 'unshare child process to do rootless stuffs'
    check_executable pacman 'install packages' get_pacman_static
}

download() { # 1: url, 2: path, 3: mod
    rm -f "$2"{,.temp}
    echo -n | install -Dm"${3:-755}" /dev/stdin "$2".temp
    eval "${log_info}" || echo "Downloading '$2' < '$1'"
    curl -qgb "" -fL --retry 3 --retry-delay 3 -o "$2".temp "$1" || return 1
    eval "${log_info}" || echo "Downloaded '$2' <= '$1'"
    mv "$2"{.temp,}
}

touched_after_start() { #1: path
    [[ $(stat -c '%Y' "$1" 2>/dev/null) -ge "${time_start_builder}" ]]
}

get_repo_db() { #1: repo url, 2: repo name
    path_db="cache/repo/$2.db"
    touched_after_start "${path_db}" && return
    download "$1/$2.db" "${path_db}"
}

get_repo_pkg() { #1: repo url, 2: repo name, 3: package
    get_repo_db "$1" "$2"
    pkg_ver=
    pkg_file=
    local line= pkg_name=
    for line in $(tar -xOf "${path_db}" --wildcards "$3"'-*/desc' | sed -n '/%FILENAME/{n;p;};/%NAME%/{n;p;};/%VERSION%/{n;p;}'); do
        [[ -z "${pkg_file}" ]] && pkg_file="${line}" && continue
        [[ -z "${pkg_name}" ]] && pkg_name="${line}" && continue
        pkg_ver="${line}"
        [[ "${pkg_name}" == "$3" ]] && break
        pkg_file=
        pkg_name=
    done
    if [[ "${pkg_name}" != "$3" ]] || [[ -z "${pkg_file}" ]] || [[ -z "${pkg_ver}" ]]; then
        eval "${log_error}" || echo "Failed to get package '$3' from repo '$2' at '$1'"
        return 1
    fi
    eval "${log_info}" || echo "Latest '$3' from repo '$2' at '$1' is at version '${pkg_ver}'"
    path_pkg=cache/pkg/"${pkg_file}"
    if [[ -f "${path_pkg}" ]]; then
        eval "${log_info}" || echo "Skipped downloading as '${path_pkg}' already exists locally"
        return
    fi
    download "$1/${pkg_file}" "${path_pkg}"
}

get_repo_pkg_file() { #1: repo url, 2: repo name, 3: package, 4: file path, 5: mod
    # local path_file="cache/pkg/$3/$4"
    # if touched_after_start "${path_file}"; then
    #     chmod "${5:-644}" "${path_file}"
    #     return
    # fi
    get_repo_pkg "$1" "$2" "$3"
    path_file="cache/pkg/$3-${pkg_ver}/$4"
    tar -xOf "cache/pkg/${pkg_file}" "$4" |
        install -Dm"${5:-644}" /dev/stdin "${path_file}"
}

get_pacman_static() {
    eval "${log_info}" || echo 'Trying to get latest pacman-static from archlinuxcn repo'
    get_repo_pkg_file http://repo.7ji.lan/archlinuxcn/x86_64 archlinuxcn pacman-static usr/bin/pacman-static 755
    eval 'pacman() { '"'${path_file}'"' "$@"; }'
}
# check_executables() {
#     local executables=(
#         'curl:download files from Internet'
#     )
#     local executable type_executable name_executable hint_executable
#     for executable in "${executables[@]}" ; do
#         name_executable="${executable%%:*}"
#         hint_executable="${executable#*:}"
#         if ! type_executable=$(type -t "${name_executable}"); then
#             eval "${log_fatal}" || echo "Could not find needed executable \"${name_executable}\". It's needed to ${hint_executable}."
#             return 1
#         fi
#         if [[ "${type_executable}" != 'file' ]]; then
#             eval "${log_fatal}" || echo "Needed executable \"${name_executable}\" exists in Bash context but it is a \"${type_executable}\" instead of a file. It's needed to ${hint_executable}."
#             return 1
#         fi
#     done
# }

argparse_main() {
    while ((  $# > 0 )); do



        shift
    done
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

guard_configure='declare -n guard="configured_${FUNCNAME#configure_}" && [[ "${guard}" ]] && return || guard=1'

require_architecture_host() {
    :
}

require_architecture_target() {
    :
}

configure_archlinux() {
    eval "${guard_configure}"
    require_architecture_target x86_64
    local mirror_arch_suffix='$repo/os/$arch'
    if [[ "${mirror_local}" ]]; then
        mirror_base="${mirror_local}/archlinux/${mirror_arch_suffix}"
    else
        mirror_base="https://geo.mirror.pkgbuild.com/${mirror_arch_suffix}"
    fi
}

configure_archlinux_x86_64() {
    eval "${guard_configure}"
    configure_archlinux
}

configure_archlinux32() {
    eval "${guard_configure}"
    require_architecture_target i486 pentium4 i686
    if [[ -z "${mirror_local}" ]]; then
        eval "${log_error}" || echo 'Arch Linux 32 does not have a globally GeoIP-based mirror and a local mirror must be defined. Please choose one from https://www.archlinux32.org/download or use your own local mirror.'
        return 1
    fi
    mirorr_base="${mirror_local}"'/archlinux32/$arch/$repo'
}

configure_archlinux32_i486() {
    eval "${guard_configure}"
    configure_archlinux32
}

configure_archlinux32_pentium4() {
    eval "${guard_configure}"
    configure_archlinux32
}

configure_archlinux32_i686() {
    eval "${guard_configure}"
    configure_archlinux32
}

configure_archlinuxarm() {
    eval "${guard_configure}"
    require_architecture_target aarch64 armv7h
    local mirror_alarm_suffix='$arch/$repo'
    if [[ "${mirror_local}" ]]; then
        mirror_base="${mirror_local}/archlinuxarm/${mirror_alarm_suffix}"
    else
        mirror_base='http://mirror.archlinuxarm.org/'"${mirror_alarm_suffix}"
    fi
}

configure_archlinuxarm_aarch64() {
    eval "${guard_configure}"
    configure_archlinuxarm
}

configure_archlinuxarm_armv7h() {
    eval "${guard_configure}"
    configure_archlinuxarm
}

configure_loongarchlinux() {
    eval "${guard_configure}"
    require_architecture_target loong64
    if [[ -z "${mirror_local}" ]]; then
        eval "${log_error}" || echo 'Loong Arch Linux does not have a globally GeoIP-based mirror and a local mirror must be defined. Please choose one from https://loongarchlinux.org/pages/download or use your own local mirror.'
        return 1
    fi
    mirorr_base="${mirror_local}"'/loongarch/archlinux/$repo/os/$arch'
}

configure_loongarchlinux_loong64() {
    eval "${guard_configure}"
    configure_loongarchlinux
}

configure_archlinuxriscv() {
    eval "${guard_configure}"
    require_architecture_target riscv64
    if [[ "${mirror_local}" ]]; then
        :
    else
        :
    fi
}

configure_archlinuxriscv_riscv64() {
    eval "${guard_configure}"
    configure_archlinuxriscv
}

configure_archlinuxcn() {
    eval "${guard_configure}"
}

guard_configure='local _included=configured_${FUNCNAME#configure_} && [[ "$configured_${FUNCNAME#configure_}" ]] && return || configured_${FUNCNAME#configure_}=1'

get_bootloader() { #1: architecture
    case "$1" in
        'x86_64')
            bootloader=systemd-boot
            ;;
        'i686'|'i486'|'pentium4')
            bootloader=syslinux
            ;;
        'aarch64')
            bootloader=uboot-bootflow
            ;;
    esac
}

argparse() {
    :

}

help_builder() {
    echo 'Usage:'
    echo "  $0 builder (--arch-host [arch]) --arch-target [arch] (--mirror-local [parent]) (--help)"
    echo
    printf -- '--%-25s %s\n' \
        'arch-host [arch]' 'overwrite the auto-detected host architecture; default: result of "uname -m"' \
        'arch-target [arch]' 'specify the target architecure; default: result of "uname -m"' \
        'help' 'print this help message' \
        'mirror-local [parent]' 'the parent of local mirror, or public mirror sites fast and close to the builder, setting this enables local mirror instead of global, some repos need always this to be set, currently it is not possible to do this on a per-repo basis; default: [none]; e.g.: https://mirrors.mit.edu'

}

applet_builder() {
    architecture_host=$(uname -m)
    architecture_target=$(uname -m)
    while (( $# > 0 )); do
        case "$1" in
        '--distribution')
            distribution="$2"
            shift
            ;;
        '--arch-host')
            architecture_host="$2"
            shift
            ;;
        '--arch-target')
            architecture_target="$2"
            shift
            ;;
        '--help')
            help_builder
            return 0
            ;;
        '--mirror-local')
            mirror_local="$2"
            shift
            ;;
        esac
    done
    PATH="${PWD}/bin:${PATH}"
    time_start_builder=$(date +%s) || time_start_builder=''
    check_executables
    [[ -z ${time_start_builder} ]] && time_start_builder=$(date +%s)
    eval "${log_info}" || echo "Builder work started at $(date -d @"${time_start_builder}")"
    eval "${log_info}" || echo "Say hello to Mr.PacMan O<. ."
    pacman --version
}

help_child() {
    echo 'Usage:'
    echo "  $0 child (--help)"
    echo
    echo '--help    print this help message'
}

applet_child() {
    while (( $# > 0 )); do
        case "$1" in
        '--help')
            help_child
            return 0
            ;;

        esac
    done
}

help_dispatch() {
    echo 'Usage:'
    echo "  $0 [applet]/--help"
    echo
    echo '[applet]  one of the following: builder, child'
    echo '--help    print this help message; for help about applets, write --help after [applet]'
}

use_namespace() { #1: namespace
    local name
    local prefix="$1::"
    local len_prefix="${#prefix}"
    for name in $(declare -F); do
        if [[ "${name}" == "${prefix}"* ]]; then
            echo "Exporting ${name} to root namespace"
            alias "${name:${len_prefix}}"="${name}"
        fi
    done
}

assert_errexit

case "$1" in
'builder')
    applet_builder "${@:2}"
    ;;
'child')
    applet_child "${@:2}"
    ;;
'--help')
    help_dispatch
    ;;
*)
    eval "${log_warn}" || echo "Unknown applet '$1', printing help message instead"
    help_dispatch
    ;;
esac
