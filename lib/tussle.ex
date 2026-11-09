defmodule Tussle do
  @moduledoc """
  An implementation of a *[tus.io](https://tus.io/)* **server** in Elixir

  > **tus** is a protocol based on HTTP for *resumable file uploads*. Resumable
  > means that an upload can be interrupted at any moment and can be resumed without
  > re-uploading the previous data again.
  >
  > An interruption may happen willingly, if the user wants to pause,
  > or by accident in case of an network issue or server outage.

  It's currently capable of accepting uploads with arbitrary sizes and storing them locally
  on disk. Due to its modularization and extensibility, support for any cloud provider
  *could* easily be added.

  ## Features

  This library implements the core TUS API v1.0.0 protocol and the following extensions:

  - [Creation](http://tus.io/protocols/resumable-upload.html#creation)
  - [Creation With Upload](https://tus.io/protocols/resumable-upload.html#creation-with-upload) -- send the first chunk with the creation request
  - [Termination](http://tus.io/protocols/resumable-upload.html#termination)
  - [Expiration](https://tus.io/protocols/resumable-upload.html#expiration) -- advertised only when `expiration_period` is configured

  Deferring the upload's length is not supported; `Upload-Length` must be known
  at creation time.


  ## Installation

  Add this repo to your list of dependencies in `mix.exs`:

  ```elixir
  def deps do
    [
      {:tussle, "~> 0.5.0"},
    ]
  end
  ```

  ## Usage

  **1. Add new controller(s)**

  ```elixir
  defmodule DemoWeb.UploadController do
    use DemoWeb, :controller
    use Tussle.Controller

    # start upload optional callback
    def on_begin_upload(file) do
      ...
      :ok  # or {:error, reason} to reject the uplaod
    end

    # Completed upload optional callback
    def on_complete_upload(file) do
      ...
    end
  end
  ```

  **2. Add routes for each of your upload controllers**

  The simplest way is to use the `Tussle.Routes` macro in your router:

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

  > **⚠️ CloudFlare Note**: CloudFlare's caching layer converts HEAD requests to GET,
  > which unexpectedly violates the expectations of the TUS protocol. The `get/:uid`
  > route above mirrors HEAD behavior to restore compatibility. See `Tussle.get/2`
  > and `Tussle.Routes` for details.

  **3. Add config for each controller (see next section)**


  ## Configuration (the global way)

  ```elixir
  # List here all of your upload controllers
  config :tussle, controllers: [DemoWeb.UploadController]

  # This is the config for the DemoWeb.UploadController
  config :tussle, DemoWeb.UploadController,
    storage: Tussle.Storage.Local,
    base_path: "priv/static/files/",

    # expire ttl for a cache entry, in seconds. If missing Expiration Protocol is not enabled
    expiration_period: 300,

    cache: Tussle.Cache.Memory,

    # max supported file size, in bytes (default 20 MB)
    max_size: 1024 * 1024 * 20
  ```

  - `storage`:
    module which handle storage file application
    This library includes only `Tussle.Storage.Local` but you can install the
    [`tus_storage_s3`](https://hex.pm/packages/tus_storage_s3) hex package to use **Amazon S3**.

  - `expiration_period`:
    expire unfinished uploads after a specified number of seconds so they can removed from cache

  - `cache`:
    module for handling the temporary uploads metadata
    This library comes with `Tussle.Cache.Memory` but you can install the
    [`tus_cache_redis`](https://hex.pm/packages/tus_cache_redis) hex package to use a **Redis** based one.

  - `max_size`:
    hard limit on the maximum size an uploaded file can have

  ### Options for `Tussle.Storage.Local`

  - `base_path`:
    where in the filesystem the uploaded files'll be stored

  ## CORS

  Tussle sets no CORS headers itself. For cross-origin browser uploads the host
  application must expose the response headers clients read back, at minimum
  `Location` and `Upload-Offset`; a browser hides them from JavaScript
  otherwise, leaving uploads unable to resume. See the README for a worked
  example and the full header list.

  """
  import Plug.Conn

  @latest_version "1.0.0"
  @supported_versions ["1.0.0"]
  @extensions ["creation", "creation-with-upload", "termination"]

  def latest_version, do: @latest_version
  def supported_versions, do: @supported_versions
  def str_supported_versions, do: Enum.join(@supported_versions, ",")

  @doc """
  The extensions supported regardless of configuration, as a `Tus-Extension` value.

  See `extension/1` for the value actually advertised for a given controller.
  """
  def extension, do: Enum.join(@extensions, ",")

  @doc """
  The extensions supported for `config`, as a `Tus-Extension` value.

  The Expiration extension is only advertised when an `:expiration_period` is
  configured, since without one no `Upload-Expires` header is ever sent.
  """
  def extension(config) do
    @extensions
    |> maybe_add_expiration(config)
    |> Enum.join(",")
  end

  defp maybe_add_expiration(extensions, config) do
    if Map.get(config, :expiration_period) do
      extensions ++ ["expiration"]
    else
      extensions
    end
  end

  def options(conn, %{max_size: max_size} = config) do
    conn
    |> put_resp_header("tus-resumable", latest_version())
    |> put_resp_header("tus-version", str_supported_versions())
    |> put_resp_header("tus-max-size", "#{max_size}")
    |> put_resp_header("tus-extension", extension(config))
    |> resp(:no_content, "")
  end

  def post(conn, %{version: version} = config) when version in @supported_versions do
    Tussle.Post.post(conn, config)
  end

  def post(conn, _config) do
    unsupported_version(conn)
  end

  def head(conn, %{version: version} = config) when version in @supported_versions do
    Tussle.Head.head(conn, config)
  end

  def head(conn, _config) do
    unsupported_version(conn)
  end

  @doc """
  Handles GET requests for upload metadata.

  This is **not** part of the TUS specification, which only defines HEAD for
  retrieving upload metadata. However, some CDN/proxy configurations (most notably
  CloudFlare) convert HEAD requests to GET requests, which unexpectedly violates
  the expectations of the TUS protocol.

  This function delegates to `head/2` and returns the same headers (`Upload-Offset`,
  `Upload-Length`, etc.) with an empty body, making it functionally equivalent to
  HEAD for clients.

  ## Why This Exists

  > **⚠️ CloudFlare Compatibility Note**
  >
  > CloudFlare's caching layer converts HEAD requests to GET requests.
  > The TUS protocol specifies HEAD for metadata retrieval, so this conversion
  > can cause requests to not match HEAD routes, resulting in 404 errors.
  > Adding a GET route that mirrors HEAD behavior restores compatibility.
  >
  > If you're using CloudFlare or similar CDNs with TUS, add both HEAD and GET
  > routes, or use `Tussle.Routes.add_tus_routes/1` which includes both automatically.

  ## Example Routes

      scope "/files", DemoWeb do
          options "/",          UploadController, :options
          post "/",             UploadController, :post
          match :head, "/:uid", UploadController, :head
          get "/:uid",          UploadController, :get  # CloudFlare compatibility
          patch "/:uid",        UploadController, :patch
          delete "/:uid",       UploadController, :delete
      end

  """
  def get(conn, %{version: version} = config) when version in @supported_versions do
    Tussle.Head.head(conn, config)
  end

  def get(conn, _config) do
    unsupported_version(conn)
  end

  def patch(conn, %{version: version} = config) when version in @supported_versions do
    Tussle.Patch.patch(conn, config)
  end

  def patch(conn, _config) do
    unsupported_version(conn)
  end

  def delete(conn, %{version: version} = config) when version in @supported_versions do
    Tussle.Delete.delete(conn, config)
  end

  def delete(conn, _config) do
    unsupported_version(conn)
  end

  defp unsupported_version(conn) do
    conn
    |> put_resp_header("tus-version", str_supported_versions())
    |> resp(:precondition_failed, "API version not supported")
  end

  @doc false
  # A request that omits Tus-Resumable is rejected exactly like one naming an
  # unsupported version: 412, carrying Tus-Version so the client can retry.
  def missing_version(conn) do
    conn
    |> put_resp_header("tus-version", str_supported_versions())
    |> resp(:precondition_failed, "API version not specified")
  end

  @doc false
  def cache_get(%{cache: cache, cache_name: cache_name, uid: uid}) do
    cache.get(cache_name, uid)
  end

  @doc false
  def cache_put(%Tussle.File{uid: uid} = file, %{cache: cache, cache_name: cache_name}) do
    cache.put(cache_name, uid, file)
  end

  @doc false
  def cache_delete(%Tussle.File{uid: uid}, %{cache: cache, cache_name: cache_name}) do
    cache.delete(cache_name, uid)
  end

  @doc false
  def storage_create(%Tussle.File{} = file, %{storage: storage} = config) do
    storage.create(file, config)
  end

  @doc false
  def storage_append(%Tussle.File{} = file, %{storage: storage} = config, data) do
    storage.append(file, config, data)
  end

  @doc false
  def storage_complete_upload(%Tussle.File{} = file, %{storage: storage} = config) do
    storage.complete_upload(file, config)
  end

  @doc false
  def storage_delete(%Tussle.File{} = file, %{storage: storage} = config) do
    storage.delete(file, config)
  end

  @doc false
  def add_expire_hdr(conn, %Tussle.File{} = file, config) do
    case {Map.get(config, :expiration_period), file.created_at} do
      {nil, _} ->
        conn

      {_, nil} ->
        conn

      {expiration_period, created_at} ->
        expire_at = created_at + expiration_period

        {:ok, dt} =
          expire_at
          |> DateTime.from_unix()

        expires = dt |> Calendar.strftime("%a, %d %b %Y %X GMT")

        conn
        |> put_resp_header("upload-expires", expires)
    end
  end
end
