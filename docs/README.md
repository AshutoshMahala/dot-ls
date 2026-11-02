# dot-ls documentation

Start with the [project README](../README.md). It tells you what dot-ls is and
how to install it.

## Find the right document

| I want to... | Read |
| --- | --- |
| Install dot-ls in Zed, or fix a Zed setup problem | [Zed guide](../editors/zed/README.md) |
| Learn what each feature does and its limits | [Features](FEATURES.md) |
| Build dot-ls, run the tests, or make a release | [Development](DEVELOPMENT.md) |
| Learn how the code is divided before I change it | [Architecture](ARCHITECTURE.md) |
| See which requirements are done and what is missing | [Requirements](REQUIREMENTS.md) |
| See speed and memory measurements | [Performance](PERFORMANCE.md) |
| Run a benchmark or read an old experiment | [Benchmark guide](../bench/README.md) |
| Find a development command | [Tools](../tools/README.md) |

## Rules for these documents

- `docs/` has six documents: this index, Features, Development, Architecture,
  Requirements and Performance. `tools/check_layout.py` checks this.
- Update a document in place when the code changes. Do not add a new document
  for each work session.
- Requirements say what is needed. Architecture says how the code is divided.
  Features say what users can do now.
- Put experiment reports in [bench/reports](../bench/reports/) and raw
  measurements in [bench/results](../bench/results/). They describe the build
  that was tested at that time. They are not current requirements.
