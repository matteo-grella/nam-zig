#!/bin/sh
# Fetch the upstream Neural Amp Modeler checkouts the README's test plan
# builds against, pinned to the commits the parity and interop records were
# taken at. Everything lands under refs/, which is gitignored: references
# are cloned and compared against, never vendored.
#
#   tools/fetch_refs.sh                        # clone/pin both references
#   tools/fetch_refs.sh NeuralAmpModelerCore   # just the named one
#
# NeuralAmpModelerCore is the runtime reference (its `render` and
# `benchmodel` tools are the parity and performance oracles; build with
# cmake as described in README.md, Test plan). neural-amp-modeler is the
# trainer reference (recipe, export schema, the v3 capture-signal table,
# and the Python re-import oracle).

set -eu
cd "$(dirname "$0")/.."
mkdir -p refs

# name|url|pinned commit
REFS='NeuralAmpModelerCore|https://github.com/sdatkinson/NeuralAmpModelerCore|e49c93e678549230d09efbb0beeb50511e387874
neural-amp-modeler|https://github.com/sdatkinson/neural-amp-modeler|a11ed88a128031c306faba79878eade51a209c48'

selected="$*"

echo "$REFS" | while IFS='|' read -r name url pin; do
    if [ -n "$selected" ]; then
        case " $selected " in *" $name "*) ;; *) continue ;; esac
    fi
    if [ ! -d "refs/$name/.git" ]; then
        echo "cloning refs/$name ..."
        git clone --quiet "$url" "refs/$name"
    fi
    git -C "refs/$name" fetch --quiet origin
    git -C "refs/$name" checkout --quiet "$pin"
    if [ -f "refs/$name/.gitmodules" ]; then
        git -C "refs/$name" submodule --quiet update --init
    fi
    echo "refs/$name @ $(git -C "refs/$name" rev-parse --short HEAD)  ($url)"
done
