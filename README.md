# LemonSeed Studio

An editor and IDE for iPad with on-device LLM inference on an AMD GPU.

LemonSeed Studio is a single iPad app. It bundles:

- **[mac_linuxgpu](https://github.com/lemonade-sdk/mac_linuxgpu):** the
  unmodified upstream Linux `amdgpu` + `amdkfd` driver, embedded in the app as
  a PCIDriverKit extension. It drives an AMD GPU in a Thunderbolt enclosure.
- **[LemonSeed Engine](https://github.com/Geramy/LSE):** the inference engine,
  running on that GPU through its HSA runtime and HRX/Loom.
- **[amdgpu_mtopg](https://github.com/lemonade-sdk/amdgpu_mtopg):** live GPU
  telemetry.

## Layout

```
third_party/mac_linuxgpu   GPU driver (submodule)
third_party/LSE            inference engine (submodule)
third_party/amdgpu_mtopg   GPU monitor (submodule)
```

## Getting the source

```sh
git clone --recurse-submodules <repository>
```

Or, in an existing clone:

```sh
git submodule update --init
```

mac_linuxgpu fetches its own pinned Linux sources sparsely on first build, so
its nested kernel submodule does not need to be cloned recursively.

## License

The original code is available under MIT or GPL-2.0-only, at your option.
See [LICENSE](LICENSE). Bundled and submodule components keep their own
licenses; see [THIRD_PARTY.md](THIRD_PARTY.md).
