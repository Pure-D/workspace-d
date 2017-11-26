#!/bin/bash

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
NORMAL="\033[0m"

COMPILER="$1"

fail_count=0
pass_count=0

echo "Running tests with ${COMPILER}..."

for testCase in tc*; do
	cd $testCase

	dub --compiler="${COMPILER}" >testout.txt 2>&1
	if [[ $? -eq 0 ]]; then
		echo -e "${YELLOW}$testCase:${NORMAL} ... ${GREEN}Pass${NORMAL}";
		rm testout.txt
		let pass_count=pass_count+1
	else
		echo -e "${YELLOW}$testCase:${NORMAL} ... ${RED}Fail${NORMAL}";
		cat testout.txt
		let fail_count=fail_count+1
	fi

	cd - > /dev/null;
done

if [[ $fail_count -eq 0 ]]; then
	echo -e "${GREEN}${pass_count} tests passed and ${fail_count} failed.${NORMAL}"
else
	echo -e "${RED}${pass_count} tests passed and ${fail_count} failed.${NORMAL}"
	exit 1
fi