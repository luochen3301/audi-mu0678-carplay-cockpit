# inputs/ (git-ignored)

| File | Where it comes from |
|---|---|
| `libaltscreen111.so`, `vc_render`, `make_patched_carplay_json.py` | `bash tools/fetch_upstream.sh` (joeyQuery/MHI2-altScreen at a pinned commit, SHA-256 checked) |
| `libaltscreen111-v11.so` | `python tools/make_hook_v11.py inputs/libaltscreen111.so inputs/libaltscreen111-v11.so` |
| `smartphone_integrator.json.patched` | `python inputs/make_patched_carplay_json.py <your collected stock smartphone_integrator.json> inputs/smartphone_integrator.json.patched` |
| `navignore/navignore_audi.jar` | your own M.I.B. V3.6.0 card, `mod/java/navignore_audi.jar` |

The build scripts check every one of these against pinned SHA-256 values and refuse to build on any mismatch.
