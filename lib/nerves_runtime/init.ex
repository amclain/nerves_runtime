defmodule Nerves.Runtime.Init do
  use GenServer
  require Logger
  alias Nerves.Runtime
  alias Nerves.Runtime.KV

  @moduledoc """
  GenServer that handles device initialization.

  Initialization currently consists of:

  1. Mounting the application partition
  2. If the application partition can't be mounted, format it, and then mount it.

  Device initialization is usually a first boot only operation. It's possible
  that device filesystems get corrupt enough to cause them to be reinitialized.
  Since corruption should be rare, Nerves systems create firmware images
  without formatting the application partition. This has the benefit of
  exercising the corruption repair code. It's also required since some
  filesystem types can only be formatted on device.

  Long format times can be problematic in manufacturing. If this is an issue,
  see if you can use F2FS since it formats much faster than ext4. Some devices
  have also had stalls when formatting while waiting for enough entropy to
  generate a UUID. Look into hardcoding UUIDs or enabling a hw random number
  generator to increase entropy.
  """

  # Use a fixed UUID for the application partition. This has two
  # purposes:
  #
  #   1. mkfs.ext4 calls generate_uuid which calls getrandom(). That
  #      call can block indefinitely until the urandom pool has been
  #      initialized. This will delay startup for a long time if the
  #      app partition needs to be reformated. (mkfs.ext4 has two calls
  #      to getrandom() so this only fixes one of them.)
  #   2. Applications that would prefer to look up a partition by UUID
  #      can do so.
  @app_partition_uuid "3041e38d-615b-48d4-affb-a7787b5c4c39"

  @spec start_link(any()) :: GenServer.on_start()
  def start_link(_args) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl GenServer
  def init(_args) do
    init_application_partition()
    {:ok, %{}}
  end

  def init_application_partition() do
    prefix = "nerves_fw_application_part0"
    fstype = KV.get_active("#{prefix}_fstype")
    target = KV.get_active("#{prefix}_target")
    devpath = KV.get_active("#{prefix}_devpath")

    %{mounted: nil, fstype: fstype, target: target, devpath: devpath, format_performed: false}
    |> do_format()
  end

  defp do_format(%{fstype: nil}), do: :noop
  defp do_format(%{target: nil}), do: :noop
  defp do_format(%{devpath: nil}), do: :noop

  defp do_format(s) do
    s
    |> mounted_state()
    |> unmount_if_error()
    |> mount()
    |> unmount_if_error()
    |> format_if_unmounted()
    |> mount()
    |> maybe_restart()
    |> validate_mount()
  end

  defp mounted_state(s) do
    {mounts, 0} = Runtime.cmd("mount", [], :return)

    %{s | mounted: parse_mount_state(s.devpath, s.target, mounts)}
  end

  @doc false
  @spec parse_mount_state(String.t(), String.t(), String.t()) ::
          :mounted | :mounted_with_error | :unmounted
  def parse_mount_state(devpath, target, mounts) do
    mount =
      String.split(mounts, "\n")
      |> Enum.find(fn mount ->
        String.starts_with?(mount, "#{devpath} on #{target}")
      end)

    case mount do
      nil ->
        :unmounted

      mount ->
        opts =
          mount
          |> String.split(" ")
          |> List.last()
          |> String.slice(1..-2)
          |> String.split(",")

        cond do
          "rw" in opts ->
            :mounted

          true ->
            # Mount was read only or any other type
            :mounted_with_error
        end
    end
  end

  defp mount(%{mounted: :mounted} = s), do: s

  defp mount(s) do
    check_cmd("mount", ["-t", s.fstype, "-o", "rw", s.devpath, s.target], :info)
    mounted_state(s)
  end

  defp unmount_if_error(%{mounted: :mounted_with_error} = s) do
    check_cmd("umount", [s.target], :info)
    mounted_state(s)
  end

  defp unmount_if_error(s), do: s

  defp format_if_unmounted(%{mounted: :unmounted, fstype: fstype, devpath: devpath} = s) do
    Logger.warn(
      "Formatting application partition. If this hangs, it could be waiting on the urandom pool to be initialized"
    )

    mkfs(fstype, devpath)
    %{s | format_performed: true}
  end

  defp format_if_unmounted(s), do: s

  defp mkfs("f2fs", devpath) do
    check_cmd("mkfs.f2fs", ["#{devpath}"], :info)
  end

  defp mkfs(fstype, devpath) do
    check_cmd("mkfs.#{fstype}", ["-U", @app_partition_uuid, "-F", "#{devpath}"], :info)
  end

  defp check_cmd(cmd, args, out) do
    case Runtime.cmd(cmd, args, out) do
      {_, 0} ->
        :ok

      _ ->
        Logger.warn("Ignoring non-zero exit status from #{cmd} #{inspect(args)}")
        :ok
    end
  end

  defp validate_mount(s), do: s.mounted

  defp maybe_restart(%{mounted: :mounted, format_performed: true} = s) do
    # If we formatted and it successfully mounted, we need to restart
    # before using the partition to prevent errors. This typically
    # only occurs on first boot
    Logger.warn("Format and mount successful - restarting...")
    :init.restart()
    s
  end

  defp maybe_restart(s), do: s
end
