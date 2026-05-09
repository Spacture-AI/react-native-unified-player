#!/usr/bin/env bash
# Builds the spactureai-mobile-player npm tarball as the package's sbuild
# artifact.
#
# This package has zero runtime `dependencies` (only `peerDependencies` like
# react / react-native / react-native-nitro-modules, which the consumer
# always supplies). So unlike spactureai-player, no `bundleDependencies`
# rewrite is needed — `npm pack` produces a self-contained tarball directly,
# carrying:
#   * lib/         (built by react-native-builder-bob from src/)
#   * src/, ios/, android/, cpp/, nitrogen/, *.podspec
# per the `files` array in package.json. CocoaPods autolinking and Android
# autolinking find these inside node_modules/spactureai-mobile-player/...
# in the consumer's tree.
#
# Outputs:
#   .pkg-build/dist/spacture-ai-mobile-player.tgz
#     A self-contained, install-anywhere npm tarball with a stable filename
#     so consumers' `file:` refs don't need to change every build.
set -euo pipefail

# This package is yarn 3 (Berry) per packageManager in package.json.
corepack enable

# Yarn 3 equivalent of `--frozen-lockfile`.
yarn install --immutable

# bob build → lib/ (TS declarations + ESM modules). The npm `files` array
# includes `lib`, so this output is what consumers actually import.
yarn prepare

rm -rf .pkg-build/dist/*
mkdir -p .pkg-build/dist

# `npm pack` is used (not `yarn pack`) for parity with spactureai-player and
# to avoid Yarn 1's depsFor / exports-field bug. Yarn 3's `yarn pack` would
# also work but `npm pack` is the same toolchain everywhere in the workspace.
npm pack --pack-destination .pkg-build/dist/

# npm names the tarball spactureai-mobile-player-<version>.tgz. Normalize to
# a stable filename so the consumer's `package.json` "file:" ref doesn't
# need to change every build.
mv .pkg-build/dist/spactureai-mobile-player-*.tgz \
   .pkg-build/dist/spacture-ai-mobile-player.tgz

ls -la .pkg-build/dist/
echo ">>> Tarball ready: .pkg-build/dist/spacture-ai-mobile-player.tgz"
