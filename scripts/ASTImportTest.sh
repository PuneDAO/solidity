#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# vim:ts=4:et
# This file is part of solidity.
#
# solidity is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# solidity is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with solidity.  If not, see <http://www.gnu.org/licenses/>
#
# (c) solidity contributors.
# ------------------------------------------------------------------------------

set -euo pipefail

REDIRECT_TO="/dev/null"
IMPORT_TEST_TYPE=
for PARAM in "$@"
do
  case "${PARAM}" in
    ast) IMPORT_TEST_TYPE="ast" ;;
    --show-errors) REDIRECT_TO="/dev/stderr"
  esac
done

# Bash script to test the import/exports.
# ast import/export tests:
#   - first exporting a .sol file to JSON, then loading it into the compiler
#     and exporting it again. The second JSON should be identical to the first.

READLINK=readlink
if [[ "$OSTYPE" == "darwin"* ]]; then
    READLINK=greadlink
fi
REPO_ROOT=$(${READLINK} -f "$(dirname "$0")"/..)
SOLIDITY_BUILD_DIR=${SOLIDITY_BUILD_DIR:-${REPO_ROOT}/build}
SOLC=${SOLIDITY_BUILD_DIR}/solc/solc
SPLITSOURCES=${REPO_ROOT}/scripts/splitSources.py

# shellcheck source=scripts/common.sh
source "${REPO_ROOT}/scripts/common.sh"

SYNTAXTESTS_DIR="${REPO_ROOT}/test/libsolidity/syntaxTests"
ASTJSONTESTS_DIR="${REPO_ROOT}/test/libsolidity/ASTJSON"

FAILED=0
UNCOMPILABLE=0
TESTED=0

if [[ "$(find . -maxdepth 0 -type d -empty)" == "" ]]; then
    fail "Test directory not empty. Skipping!"
fi

function ast_import_export_equivalence
{
    local sol_file="$1"
    local input_files="$2"
    # save exported json as expected result (silently)
    $SOLC --combined-json ast --pretty-json --json-indent 4 "${input_files}" > expected.json 2> ${REDIRECT_TO}
    # import it, and export it again as obtained result (silently)
    if ! $SOLC --import-ast --combined-json ast --pretty-json --json-indent 4 expected.json > obtained.json 2> stderr.txt
    then
        # For investigating, use exit 1 here so the script stops at the
        # first failing test
        # exit 1
        FAILED=$((FAILED + 1))
        printError "ERROR: AST reimport failed for input file $sol_file"
        printError
        printError "Compiler stderr:"
        cat ./stderr.txt >&2
        printError
        printError "Compiler stdout:"
        cat ./obtained.json >&2
        return 1
    fi
    if ! diff_files expected.json obtained.json
    then
        FAILED=$((FAILED + 1))
    fi
    TESTED=$((TESTED + 1))
    rm expected.json obtained.json
    rm -f stderr.txt
}

# function tests whether exporting and importing again is equivalent.
# Results are recorded by adding to FAILED or UNCOMPILABLE.
# Also, in case of a mismatch a diff is printed
# Expected parameters:
# $1 name of the file to be exported and imported
# $2 any files needed to do so that might be in parent directories
function testImportExportEquivalence {
    local sol_file="$1"
    local input_files="$2"
    if "$SOLC" --bin "${input_files}" > ${REDIRECT_TO} 2>&1
    then
        ! [[ -e stderr.txt ]] || fail "stderr.txt already exists. Refusing to overwrite."
        case "$IMPORT_TEST_TYPE" in
          ast) ast_import_export_equivalence "${sol_file}" "${input_files}" ;;
          *) fail "Unknown import test type. Aborting." ;;
        esac
    else
        UNCOMPILABLE=$((UNCOMPILABLE + 1))
    fi
}

WORKINGDIR=$PWD

command_available "${SOLC}" --version
command_available jq --version

case "$IMPORT_TEST_TYPE" in
    ast) TEST_DIRS=("${SYNTAXTESTS_DIR}" "${ASTJSONTESTS_DIR}") ;;
    *) fail "Unknown import test type. Aborting. Please specify ${0} ast [--show-errors]." ;;
esac

# boost_filesystem_bug specifically tests a local fix for a boost::filesystem
# bug. Since the test involves a malformed path, there is no point in running
# tests on it. See https://github.com/boostorg/filesystem/issues/176
IMPORT_TEST_FILES=$(find "${TEST_DIRS[@]}" -name "*.sol" -and -not -name "boost_filesystem_bug.sol")

NSOURCES="$(echo "$IMPORT_TEST_FILES" | wc -l)"
echo "Looking at $NSOURCES .sol files..."

for solfile in ${IMPORT_TEST_FILES}
do
    echo -n "."
    # create a temporary sub-directory
    FILETMP=$(mktemp -d)
    cd "$FILETMP"

    set +e
    OUTPUT=$("$SPLITSOURCES" "$solfile")
    SPLITSOURCES_RC=$?
    set -e
    if [[ ${SPLITSOURCES_RC} == 0 ]]
    then
        IFS=' ' read -ra OUTPUT_ARRAY <<< "${OUTPUT}"
        NSOURCES=$((NSOURCES - 1 + ${#OUTPUT_ARRAY[@]}))
        testImportExportEquivalence "$solfile" "${OUTPUT_ARRAY[*]}"
    elif [ ${SPLITSOURCES_RC} == 1 ]
    then
        testImportExportEquivalence "$solfile" "$solfile"
    elif [ ${SPLITSOURCES_RC} == 2 ]
    then
        # The script will exit with return code 2, if an UnicodeDecodeError occurred.
        # This is the case if e.g. some tests are using invalid utf-8 sequences. We will ignore
        # these errors, but print the actual output of the script.
        printError "\n\n${OUTPUT}\n\n"
        testImportExportEquivalence "$solfile" "$solfile"
    else
        # All other return codes will be treated as critical errors. The script will exit.
        printError "\n\nGot unexpected return code ${SPLITSOURCES_RC} from ${SPLITSOURCES}. Aborting."
        printError "\n\n${OUTPUT}\n\n"

        cd "$WORKINGDIR"
        # Delete temporary files
        rm -rf "$FILETMP"

        exit 1
    fi

    cd "$WORKINGDIR"
    # Delete temporary files
    rm -rf "$FILETMP"
done

echo

if (( FAILED == 0 ))
then
    echo "SUCCESS: $TESTED tests passed, $FAILED failed, $UNCOMPILABLE could not be compiled ($NSOURCES sources total)."
else
    fail "FAILURE: Out of $NSOURCES sources, $FAILED failed, ($UNCOMPILABLE could not be compiled)."
fi
