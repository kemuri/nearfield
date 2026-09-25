## Nearfield audio driver

Nearfield's HAL audio driver, forked from Brian Kendall's
[Proxy Audio Device](https://github.com/briankendall/proxy-audio-device), which is
in the public domain (see [LICENSE](LICENSE)).

The driver provides the Nearfield output device and plays it through a private
aggregate of the Studio Displays. The Nearfield app installs and configures it;
the upstream settings app is not part of this fork.

From the repository root, build it with `./script/build_router_driver.sh` and
test it with `./script/test_router_driver.sh`.
