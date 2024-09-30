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
    check_executable_must_exist sed 'do text substitution'
    check_executable_must_exist uname 'dump machine architecture'
    check_executable_must_exist unshare 'unshare child process to do rootless stuffs'
    check_executable pacman 'install packages' prepare_pacman
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

get_pacman_conf() { #1: distro, $2: architecture
    case "$1" in
        'Arch Linux')
            ;;
        'Arch Linux ARM')
            ;;
        'Loong Arch Linux')
            ;;
    esac
}

get_mirror() { #1: distro (stylised whole name), #2: architecture (pacman.conf value)
    local mirror_local="${mirror_local:-https://mirrors.tuna.tsinghua.edu.cn}"
    local mirror_alarm_global='http://mirror.archlinuxarm.org/$arch/$repo'
    local mirror_alarm_local="${mirror_local}"'/archlinuxarm/$arch/$repo'
    local mirror_arch_global='https://geo.mirror.pkgbuild.com/$repo/os/$arch'
    local mirror_arch_local="${mirror_local}"'/archlinux/$arch/$repo'
    case "$1 @ $2" in
        'Arch Linux @ x86_64')
            mirror_base_global="${mirror_arch_global}"
            mirror_base_local="${mirror_arch_local}"
            ;;
        'Arch Linux ARM @ aarch64')
            mirror_base_global="${mirror_alarm_global}"
            mirror_base_local="${mirror_alarm_local}"
            ;;
        'Arch Linux ARM @ armv7h')
            mirror_base_global="${mirror_alarm_global}"
            mirror_base_local="${mirror_alarm_local}"
            ;;
        'Loong Arch Linux @ loong64')
            :
            ;;
        *)
            eval "${log_fatal}" || echo "Unknown distribution '$1' and architecture '$2' combination"
            return 1
            ;;
    esac
}

argparse() {
    :

}

help_builder() {
    echo 'Usage:'
    echo "  $0 builder (--help)"
    echo
    echo '--help    print this help message'

}

applet_builder() {
    distribution="${AIMAGER_DISTRIBUTION}"
    architecture="${AIMAGER_ARCHITECTURE}"
    while (( $# > 0 )); do
        case "$1" in
        '--help')
            help_builder
            return 0
            ;;
        '--distribution')
            distribution="$2"
            shift
            ;;
        '--architecture')
            architecture="$2"
            shift
            ;;
        esac
    done
    PATH="${PWD}/bin:${PATH}"
    check_executables
    eval "${log_debug}" || echo 'Hello there'
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
    echo "  $0 [applet]/(--)help"
    echo
    echo '[applet]  one of the following: builder, child'
    echo '--help    print this help message, for help about applets, write --help after [applet]'
}

assert_errexit
case "$1" in
'builder')
    applet_builder "${@:2}"
    ;;
'child')
    applet_child "${@:2}"
    ;;
'--help' | 'help')
    help_dispatch
    ;;
*)
    eval "${log_warn}" || echo "Unknown applet '$1', printing help message instead"
    help_dispatch
    ;;
esac