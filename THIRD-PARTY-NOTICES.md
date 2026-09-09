# Third-party notices

nam-zig is licensed under the MIT License (see `LICENSE`). This file
inventories every third-party component in the tree, grouped by how the
material got here:

- **Vendored**: third-party source code or data copied into this repository.
- **Ported**: Zig reimplementations of third-party code; the Zig files are
  nam-zig's, the design and in places the operation-for-operation structure
  are upstream's.
- **Dependency**: fetched by the Zig package manager at build time, not
  redistributed here.
- **Parity reference**: no code copied; the implementation is validated to
  match the upstream's output.

## Vendored code and data

| Component | Files | Upstream | License |
| --- | --- | --- | --- |
| miniaudio v0.11.25 (single-header audio I/O) | `src/third_party/miniaudio.h` | [mackron/miniaudio](https://github.com/mackron/miniaudio) | Dual: public domain (Unlicense) **or** MIT No Attribution, at your option. Copyright 2026 David Reid; full texts in the vendored header |
| Standardized loudness-measurement signal (1 s, 48 kHz, 24-bit) | `src/resources/loudness_input.wav` | [sdatkinson/neural-amp-modeler](https://github.com/sdatkinson/neural-amp-modeler) `nam/models/_resources/`, commit a11ed88 | MIT |
| Four tiny format-parity fixtures (`wavenet`, `lstm`, `slimmable_wavenet`, `slimmable_container`) | `src/testdata/*.nam` | [sdatkinson/NeuralAmpModelerCore](https://github.com/sdatkinson/NeuralAmpModelerCore) `example_models/`, commit e49c93e | MIT |

## Ported code

| Component | Files | Upstream | License |
| --- | --- | --- | --- |
| Neural Amp Modeler runtime: the `.nam` format and its loader, the WaveNet / LSTM / ConvNet / Linear architectures, the cabinet impulse response, the loudness and gain metadata contract | `src/` | [sdatkinson/NeuralAmpModelerCore](https://github.com/sdatkinson/NeuralAmpModelerCore) | MIT |
| Trainer recipe (data checks, latency calibration, ESR bands, the standard / A2 / packed configurations, export schema) | `src/data.zig`, `src/train.zig`, `src/nam_export.zig` | [sdatkinson/neural-amp-modeler](https://github.com/sdatkinson/neural-amp-modeler) | MIT |

## Dependency

| Component | Role | Upstream | License |
| --- | --- | --- | --- |
| Fucina (tensor library: the streaming causal convolutions, the LSTM sequence op, autograd, optimizers, GGUF I/O) | `build.zig.zon` dependency, pinned by tag and content hash | [matteo-grella/fucina](https://github.com/matteo-grella/fucina) | MIT |

## Parity references (no code copied)

The upstream `NeuralAmpModelerCore` `render` and `benchmodel` tools and the
`neural-amp-modeler` Python trainer are the oracles the README's test plan
compares against; `tools/fetch_refs.sh` pins both at the commits the
recorded numbers were taken at. Nothing from them is redistributed here.

## MIT license text

The MIT-licensed components above are used under the standard MIT License;
the copyright holder for each is named in its entry, and vendored files
carry their original headers. The full MIT text is reproduced in this
repository's `LICENSE` file.
