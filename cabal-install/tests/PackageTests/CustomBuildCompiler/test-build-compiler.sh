#!/bin/bash

echo "%% CUSTOM BUILD COMPILER USED %%" > test-dir/TEST_BUILD_COMPILER_OUTPUT

ghc $@ | tee -a test-dir/TEST_BUILD_COMPILER_OUTPUT
