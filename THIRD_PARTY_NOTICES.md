# Third-party notices

## Stats

TileDeck's names for individual Apple Silicon temperature sensors (CPU
performance and efficiency cores, GPU cores, memory, airflow and storage SMC
keys, in `Sources/TileDeck/Features/Fans/FanMonitor.swift`) follow the sensor
table of [Stats](https://github.com/exelban/stats), used under the MIT License:

```
MIT License

Copyright (c) 2019 Serhiy Mytrovtsiy

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Techniques learned from other open-source projects

No code from these projects is included; TileDeck re-implements the same
publicly documented techniques:

- [MonitorControl](https://github.com/MonitorControl/MonitorControl) — DDC/CI over IOAVService on Apple Silicon.
- [AltTab](https://github.com/lwouis/alt-tab-macos) — focusing windows across Spaces, finding other-Space windows through remote AX tokens.
- [Ice](https://github.com/jordanbaird/Ice) — moving menu bar items with ⌘-drag events while the pointer is hidden.
