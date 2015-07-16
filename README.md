# gateblu-forever

[![Build Status](https://travis-ci.org/octoblu/gateblu-forever.svg?branch=master)](https://travis-ci.org/octoblu/gateblu-forever)
[![Build status](https://ci.appveyor.com/api/projects/status/v12s4x3xaso35ubq?svg=true)](https://ci.appveyor.com/project/OctobluInc/gateblu-forever)
[![Code Climate](https://codeclimate.com/github/octoblu/gateblu-forever/badges/gpa.svg)](https://codeclimate.com/github/octoblu/gateblu-forever)
[![Test Coverage](https://codeclimate.com/github/octoblu/gateblu-forever/badges/coverage.svg)](https://codeclimate.com/github/octoblu/gateblu-forever)


Gateblu-Forever will automatically register itself with meshblu.octoblu.com on startup.


## Install

```
npm install -g gateblu-forever
```

## Config
If `meshblu.json` does not exist, Gateblu will automatically register a new device and create the file.

Sample `meshblu.json`

```
{
  "server": "meshblu.octoblu.com",
  "port": "80",
  "devicePath": "devices",
  "tmpPath": "tmp",
  "uuid": "c4110691-69fd-11e4-b75c-63db18512b02",
  "token": "0kmpejq8ul434n29pbti61d2q4vg3nmi"
}
```

## Usage

```
gateblu-service
```

### Debug Output

```
DEBUG=* gateblu-service
```

### Skip Connector Install
```
gateblu-service --skip-install
```
You may also use environment variables
```
GATEBLU_SKIP_INSTALL=true gateblu-service
```
