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
## Callers shall log like this: eval "${log_info}" && echo 'Log content' ||:
## When a logging level is enabled the above is effectively echo -n  '[INFO] function_name@line_no: ' && echo 'Log content'
## When a logging level is disabled the above is effectively false ||:
## The ||: part is needed to make sure logging statement always return 0, because when some 
log_common_start='echo -n "['
log_common_end='] ${FUNCNAME}@${LINENO}: "'
log_info="${log_common_start}INFO${log_common_end}"
log_warn="${log_common_start}WARN${log_common_end}"
log_error="${log_common_start}ERROR${log_common_end}"
log_fatal="${log_common_start}FATAL${log_common_end}"

# Debugging-only definitions
if [[ "${aimager_debug}" ]]; then
log_debug="${log_common_start}DEBUG${log_common_end}"

# Assert variables are defined and non-empty
## $1: caller (for logging)
## $2...: vairable names
assert_declared() {
    eval "${log_debug}" && echo "Asserting variables for $1: ${*:2}" ||:
    local _bad= _var=
    while (( $# > 1 )); do
        if [[ ! -v $2 ]]; then
            eval "${log_fatal}" && echo "Variable \"$2\" is not declared" ||:
            _bad='y'
            shift
            continue
        fi
        declare -n _var="$2"
        if [[ -z "${_var}" ]]; then
            eval "${log_fatal}" && echo "Variable \"$2\" is empty" ||:
            _bad='y'
        fi
        shift
    done
    if [[ "${_bad}" ]]; then
        eval "${log_fatal}" && echo 'Declaration assertion failed' ||:
        exit 1
    fi
}
assert_declared_this_func='assert_declared "${FUNCNAME}@${LINENO}" '
else # Empty function bodies and short paths when debugging is not enabled, 
log_debug='false'
assert_declared() { :; }
assert_declared_this_func="true||"
fi

# check if an executable exists
## $1: executable name
## $2: hint
## $3: missing callback

check_executable() { 
    local type_executable
    if ! type_executable=$(type -t "$1"); then
        eval "${log_fatal}" && echo "Could not find needed executable \"$1\". It's needed to $2." ||:
        "$3"
        if ! type_executable=$(type -t "$1"); then
            eval "${log_fatal}" && echo "Still could not find needed executable \"$1\" after callback \"$3\". It's needed to $2." ||:
            return 1
        fi
        # explicit fallthrough: unless callback is false, we would check whether the executable becomes available after callback
    fi
    if [[ "${type_executable}" != 'file' ]]; then
        eval "${log_fatal}" && echo "Needed executable \"${name_executable}\" exists in Bash context but it is a \"${type_executable}\" instead of a file. It's needed to $2." ||:
        return 1
    fi
}

# check_executable with pre-defined 'false' callback (break if non-existing)
check_executable_must_exist() {
    check_executable "$1" "$2" 'false'
}

check_executables() {
    check_executable_must_exist curl 'download files from Internet'
    check_executable_must_exist sed2 'do text substitution'
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
#             eval "${log_fatal}" && echo "Could not find needed executable \"${name_executable}\". It's needed to ${hint_executable}." ||:
#             return 1
#         fi
#         if [[ "${type_executable}" != 'file' ]]; then
#             eval "${log_fatal}" && echo "Needed executable \"${name_executable}\" exists in Bash context but it is a \"${type_executable}\" instead of a file. It's needed to ${hint_executable}." ||:
#             return 1
#         fi
#     done
# }

load_lazily() {
    
}

# try_

# Needed:
generate_pacman_config() {
    :
}



argparse_main() {
    while ((  $# > 0 )); do



        shift
    done
}

my_callback() {
    echo hello
}

assert_errexit() {
    if [[ $- != *e* ]]; then
        eval "${log_fatal}" && echo 'The script must be run with -e' || :
        exit 1
    fi
}

main() {
    assert_errexit
    check_executables
    eval "${log_debug}" && echo 'Hello there' ||:
}
main