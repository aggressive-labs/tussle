# Tussle

[![Tests](https://github.com/aggressive-labs/tussle/actions/workflows/main.yml/badge.svg)](https://github.com/aggressive-labs/tussle/actions/workflows/main.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/tussle.svg)](https://hex.pm/packages/tussle)
[![HexDocs](https://img.shields.io/badge/hex-docs-blue)](https://hexdocs.pm/tussle/)
[![GitHub stars](https://img.shields.io/github/stars/aggressive-labs/tussle.svg)](https://github.com/aggressive-labs/tussle/stargazers)
[![Sponsor](https://img.shields.io/badge/sponsor-%E2%9D%A4-lightgrey)](https://github.com/sponsors/jvantuyl)

An implementation of a *[tus](https://tus.io/)* **server** in Elixir

**Documentation: https://hexdocs.pm/tussle/**

> **tus** is a protocol based on HTTP for *resumable file uploads*. Resumable
> means that an upload can be interrupted at any moment and can be resumed without
> re-uploading the previous data again.
>
> An interruption may happen willingly, if the user wants to pause,
> or by accident in case of an network issue or server outage.

Tussle is capable of accepting uploads with arbitrary sizes and storing them locally
on disk, or in Amazon S3 by installing the [`tus_storage_s3`](https://hex.pm/packages/tus_storage_s3) hex package.
Due to its modularization and extensibility, support for any other cloud provider can be easily added.

## Features

This library implements the core TUS API v1.0.0 protocol and the following extensions:

- [Creation](http://tus.io/protocols/resumable-upload.html#creation)
- [Creation With Upload](https://tus.io/protocols/resumable-upload.html#creation-with-upload) -- send the first chunk with the creation request
- [Termination](http://tus.io/protocols/resumable-upload.html#termination)
- [Expiration](https://tus.io/protocols/resumable-upload.html#expiration) -- advertised only when `expiration_period` is configured

Deferring the upload's length is not supported; `Upload-Length` must be known at
creation time.

## Installation

Add this repo to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:tussle, "~> 0.4.0"},
  ]
end
```

## Usage

**1. Add new controller(s)**

```elixir
defmodule DemoWeb.UploadController do
  use DemoWeb, :controller
  use Tussle.Controller

  # Optional callback before upload starts
  def on_begin_upload(file) do
    ...
    :ok  # or {:error, reason} to reject the upload
  end

  # Optional callback when upload completes
  def on_complete_upload(file) do
    ...
  end
end
```

**2. Add routes for each of your upload controllers**

The simplest way is to use the `Tussle.Routes` macro:

```elixir
defmodule DemoWeb.Router do
  use DemoWeb, :router
  import Tussle.Routes

  scope "/files", DemoWeb do
    pipe_through :api
    add_tus_routes UploadController
  end
end
```

Or define routes manually:

```elixir
scope "/files", DemoWeb do
    options "/",          UploadController, :options
    post "/",             UploadController, :post
    match :head, "/:uid", UploadController, :head
    get "/:uid",          UploadController, :get  # CloudFlare compatibility
    patch "/:uid",        UploadController, :patch
    delete "/:uid",       UploadController, :delete
end
```

> **⚠️ CloudFlare Compatibility Note**
>
> CloudFlare's caching layer converts HEAD requests to GET requests.
> The TUS protocol specifies HEAD for metadata retrieval, so this conversion
> can cause requests to not match HEAD routes, resulting in 404 errors.
>
> The `add_tus_routes/1` macro includes a GET route that mirrors HEAD behavior
> automatically. If you define routes manually, you must add the GET route yourself
> to ensure resumable uploads work correctly behind CloudFlare or similar CDNs.

**3. Add config for each controller (see next section)**

## Configuration

```elixir
# List all of your upload controllers
config :tussle, controllers: [DemoWeb.UploadController]

# Configuration for the DemoWeb.UploadController
config :tussle, DemoWeb.UploadController,
  storage: Tussle.Storage.Local,
  base_path: "priv/static/files/",

  # Optional: expire unfinished uploads after N seconds
  expiration_period: 300,

  cache: Tussle.Cache.Memory,

  # max supported file size, in bytes (default 20 MB)
  max_size: 1024 * 1024 * 20
```

- `storage`: module which handles file storage. This library includes `Tussle.Storage.Local`.
  Install the [`tus_storage_s3`](https://hex.pm/packages/tus_storage_s3) hex package for **Amazon S3** support.
- `expiration_period`: expire unfinished uploads after a specified number of seconds.
- `cache`: module for handling temporary upload metadata. This library includes `Tussle.Cache.Memory`.
  Install the [`tus_cache_redis`](https://hex.pm/packages/tus_cache_redis) hex package for **Redis** support.
- `max_size`: hard limit on the maximum size an uploaded file can have.

### Options for `Tussle.Storage.Local`

- `base_path`: where in the filesystem the uploaded files will be stored

### Read Body Options

These options control how the server reads upload request bodies:

```elixir
config :tussle,
  read_body_length: 100_000_000,      # max body size in bytes (default: 100MB)
  read_body_read_length: 262_144,     # chunk size for reading (default: 256KB)
  read_body_timeout: 30_000            # timeout per read in ms (default: 30s)
```

- `read_body_length`: Maximum allowed request body size. Increase for very large file uploads.
- `read_body_read_length`: Size of chunks read from the socket. Larger values improve throughput for big files but use more memory per read.
- `read_body_timeout`: Maximum time to wait for each chunk. Increase for slow clients or unreliable networks.

## CORS

Tussle sets no CORS headers of its own. If your uploads come from a browser on a
different origin than the API, the host application must add them, and **an
incomplete `Access-Control-Expose-Headers` list is the most common cause of
uploads that appear to succeed but never resume**: a browser hides
`Upload-Offset` and `Location` from JavaScript unless they are explicitly
exposed, so the client cannot learn where to resume from.

Using [`cors_plug`](https://hex.pm/packages/cors_plug) as an example (it is not
a Tussle dependency, any CORS plug will do):

```elixir
plug CORSPlug,
  origin: ["https://app.example.com"],
  methods: ["OPTIONS", "POST", "HEAD", "GET", "PATCH", "DELETE"],

  # Request headers tus clients send.
  headers: [
    "Authorization",
    "Content-Type",
    "Tus-Resumable",
    "Upload-Length",
    "Upload-Offset",
    "Upload-Metadata",
    "X-HTTP-Method-Override",
    "X-Requested-With"
  ],

  # Response headers the client must be able to read.
  expose: [
    "Location",
    "Tus-Resumable",
    "Tus-Version",
    "Tus-Extension",
    "Tus-Max-Size",
    "Upload-Offset",
    "Upload-Length",
    "Upload-Metadata",
    "Upload-Expires"
  ]
```

Two further notes:

- `PATCH` must be in the allowed methods. Where it cannot be (some proxies strip
  it), clients can fall back to `POST` with `X-HTTP-Method-Override: PATCH`,
  which Tussle honours.
- Keep the preflight cache short while you are still tuning this list, otherwise
  browsers will keep reusing a stale, too-narrow preflight response.

## Protocol Compatibility

Tussle implements the tus 1.0.0 core protocol and works with current
[tus-js-client](https://github.com/tus/tus-js-client) releases out of the box.
See [docs/UPSTREAM_COMPAT.md](docs/UPSTREAM_COMPAT.md) for which tus extensions
are still missing, where the IETF *Resumable Uploads for HTTP* standardisation
effort stands, and an effort estimate for closing each gap.

## About This Fork

This is a maintained fork of the original [`tus`](https://hex.pm/packages/tus) package. The package was renamed to **Tussle** to allow publishing updated versions to Hex without conflicting with the original (now unmaintained) package.

## Acknowledgments

Thank you to the original author of this library and all the people who graciously published their improvements that I have integrated into this fork.

- **Juan-Pablo Scaletti** ([jpscaletti](https://github.com/jpsca)) -- original author
- **Pierre-Louis Gottfrois** ([gottfrois](https://github.com/gottfrois)) -- maintained the primary fork, merged community PRs
- **Marcin Koziej** ([marcinkoziej](https://github.com/marcinkoziej)) -- init_file callback, missing config handling, empty metadata fix
- **Davide Colombo** ([davec82](https://github.com/davec82)) -- expiration protocol, on_complete_upload result checking, empty metadata values
- **Zachary Kessin** ([zkessin](https://github.com/zkessin)) -- location prefix support
- **Stephen Solka** ([Clause-Logic](https://github.com/Clause-Logic)) -- storage provider offset control
- **Kevin Pan** ([feng19](https://github.com/feng19)) -- source_url fix
- **Ringo De Smet** ([ringods](https://github.com/ringods)) -- Storage behaviour, File typespecs, metadata as map
- **Alexander Buch** ([bucha](https://github.com/bucha)) -- multiple cache support
- **Joel Jucá** ([joeljuca](https://github.com/joeljuca)) -- mix.exs formatting fix

## Contributors

<!-- readme: jvantuyl,collaborators,contributors,sponsors,bots/- -start -->
<table>
	<tbody>
		<tr>
            <td align="center">
                <a href="https://github.com/jvantuyl">
                    <img src="https://avatars.githubusercontent.com/u/101?v=4" width="100;" alt="jvantuyl"/>
                    <br />
                    <sub><b>Jayson Vantuyl</b></sub>
                </a>
            </td>
            <td align="center">
                <a href="https://github.com/jpsca">
                    <img src="https://avatars.githubusercontent.com/u/67524204?v=4" width="100;" alt="jpsca"/>
                    <br />
                    <sub><b>Juan-Pablo Scaletti</b></sub>
                </a>
            </td>
            <td align="center">
                <a href="https://github.com/gottfrois">
                    <img src="https://avatars.githubusercontent.com/u/943784?v=4" width="100;" alt="gottfrois"/>
                    <br />
                    <sub><b>Pierre-Louis Gottfrois</b></sub>
                </a>
            </td>
            <td align="center">
                <a href="https://github.com/marcinkoziej">
                    <img src="https://avatars.githubusercontent.com/u/156725?v=4" width="100;" alt="marcinkoziej"/>
                    <br />
                    <sub><b>Marcin Koziej</b></sub>
                </a>
            </td>
            <td align="center">
                <a href="https://github.com/ringods">
                    <img src="https://avatars.githubusercontent.com/u/77923?v=4" width="100;" alt="ringods"/>
                    <br />
                    <sub><b>Ringo De Smet</b></sub>
                </a>
            </td>
            <td align="center">
                <a href="https://github.com/joeljuca">
                    <img src="https://avatars.githubusercontent.com/u/673884?v=4" width="100;" alt="joeljuca"/>
                    <br />
                    <sub><b>Joel Jucá</b></sub>
                </a>
            </td>
		</tr>
		<tr>
            <td align="center">
                <a href="https://github.com/feng19">
                    <img src="https://avatars.githubusercontent.com/u/2451508?v=4" width="100;" alt="feng19"/>
                    <br />
                    <sub><b>Kevin Pan</b></sub>
                </a>
            </td>
            <td align="center">
                <a href="https://github.com/zkessin">
                    <img src="https://avatars.githubusercontent.com/u/1738082?v=4" width="100;" alt="zkessin"/>
                    <br />
                    <sub><b>Zachary Kessin</b></sub>
                </a>
            </td>
            <td align="center">
                <a href="https://github.com/github-actions[bot]">
                    <img src="https://avatars.githubusercontent.com/in/15368?v=4" width="100;" alt="github-actions[bot]"/>
                    <br />
                    <sub><b>github-actions[bot]</b></sub>
                </a>
            </td>
		</tr>
	<tbody>
</table>
<!-- readme: jvantuyl,collaborators,contributors,sponsors,bots/- -end -->

## License

BSD-3-Clause. See [LICENSE](LICENSE) for details.
