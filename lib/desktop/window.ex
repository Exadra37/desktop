defmodule Desktop.Window do
  @moduledoc ~S"""
  Defines a Desktop Window.

  The window hosts a Phoenix Endpoint and displays its content.
  It should be part of a supervision tree and is the main interface
  to interact with your application.

  In total the window is doing:

    * Displaying the endpoint content

    * Hosting and starting an optional menu bar

    * Controlling a taskbar icon if present

  ## The Window

  You can add the Window to your own Supervision tree:

      children = [{
        Desktop.Window,
        [
          app: :your_app,
          id: YourAppWindow,
          title: "Your App Title",
          size: {600, 500},
          icon: "icon.png",
          menubar: YourApp.MenuBar,
          icon_menu: YourApp.Menu,
          url: fn -> YourAppWeb.Router.Helpers.live_url(YourAppWeb.Endpoint, YourAppWeb.YourAppLive) end
        ]
      }]


  ### Window configuration

  Phoenix allows you to choose which webserver adapter to use. The default
  is `Phoenix.Endpoint.Cowboy2Adapter` which can be configured via the
  following options.

    * `:app` - your app name within which the Window is running.

    * `:id` - an atom identifying the window. Can later be used to control the
      window using the functions of this module.

    * `:title` - the window title that will be show initially. The window
      title can be set later using `set_title/2`.

    * `:size` - the initial windows size in pixels {width, height}.

    * `:hidden` - whether the window should be initially hidden defaults to false

        Possible values are:

        * `false` - Show the window on startup (default)
        * `true` - Don't show the window on startup

    * `:icon` - an icon file name that will be used as taskbar and
      window icon. Supported formats are png files

    * `:menubar` - an optional MenuBar module that will be rendered
      as the windows menu bar when given.

    * `:icon_menu` - an optional MenuBar module that will be rendered
      as menu onclick on the taskbar icon.

    * `:url` - a callback to the initial (default) url to show in the
      window.

  """

  alias Desktop.{OS, Window, Wx, Menu, Fallback}
  require Logger
  use GenServer

  @enforce_keys [:frame]
  defstruct [
    :module,
    :taskbar,
    :frame,
    :notifications,
    :webview,
    :home_url,
    :last_url,
    :title,
    :rebuild,
    :rebuild_timer
  ]

  @doc false
  def child_spec(opts) do
    app = Keyword.fetch!(opts, :app)
    id = Keyword.fetch!(opts, :id)

    %{
      id: id,
      start: {__MODULE__, :start_link, [opts ++ [app: app, id: id]]}
    }
  end

  @doc false
  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    {_ref, _num, _type, pid} = :wx_object.start_link({:local, id}, __MODULE__, opts, [])
    {:ok, pid}
  end

  @impl true
  @doc false
  def init(options) do
    window_title = options[:title] || Atom.to_string(options[:id])
    size = options[:size] || {600, 500}
    app = options[:app]
    icon = options[:icon] || "icon.png"
    menubar = options[:menubar]
    icon_menu = options[:icon_menu]
    hidden = options[:hidden] || false
    url = options[:url]

    env = Desktop.Env.wx_env()
    GenServer.cast(Desktop.Env, {:register_window, self()})
    :wx.set_env(env)

    frame =
      :wxFrame.new(Desktop.Env.wx(), Wx.wxID_ANY(), window_title, [
        {:size, size},
        {:style, Wx.wxDEFAULT_FRAME_STYLE()}
      ])

    :wxFrame.connect(frame, :close_window)
    :wxFrame.setSizer(frame, :wxBoxSizer.new(Wx.wxHORIZONTAL()))

    # This one-line version will not show right on MacOS:
    # icon = :wxIcon.new(Path.join(:code.priv_dir(app), icon))

    # This 5-line version does show right though:
    image = :wxImage.new(Path.join(:code.priv_dir(app), icon))
    bitmap = :wxBitmap.new(image)
    icon = :wxIcon.new()
    :wxIcon.copyFromBitmap(icon, bitmap)
    :wxBitmap.destroy(bitmap)

    :wxTopLevelWindow.setIcon(frame, icon)

    if menubar do
      # if OS.type() == MacOS do
      #   :wxMenuBar.oSXGetAppleMenu(:wxMenuBar.new())
      # else
      {:ok, pid} = Menu.start_link(menubar, env, :wxMenuBar.new())
      :wxFrame.setMenuBar(frame, Menu.menubar(pid))
    else
      # MacOS osMenu
      if OS.type() == MacOS do
        :wxMenu.connect(:wxMenuBar.oSXGetAppleMenu(:wxMenuBar.new()), :command_menu_selected)
      end
    end

    taskbar =
      if icon_menu do
        {:ok, pid} = Menu.start_link(icon_menu, env, {:taskbar, icon})

        :wxTaskBarIcon.connect(Menu.taskbar(pid), :taskbar_left_down, skip: true)
        :wxTaskBarIcon.connect(Menu.taskbar(pid), :taskbar_right_down, skip: true)

        pid
      end

    timer =
      if OS.type() == Windows do
        {:ok, timer} = :timer.send_interval(500, :rebuild)
        timer
      end

    ui = %Window{
      frame: frame,
      webview: Fallback.webview_new(frame),
      notifications: %{},
      home_url: url,
      title: window_title,
      taskbar: taskbar,
      rebuild: 0,
      rebuild_timer: timer
    }

    if hidden != true do
      show(self(), url)
    end

    {frame, ui}
  end

  @doc """
  Show the Window if not visible with the given url.

    * `pid` - The pid or atom of the Window
    * `url` - The endpoint url to show. If non is provided
      the url callback will be used to get one.

  ## Examples

      iex> Desktop.Window.show(pid, "/")
      :ok

  """
  def show(pid, url \\ nil) do
    GenServer.cast(pid, {:show, url})
  end

  @doc """
  Set the windows title

    * `pid` - The pid or atom of the Window
    * `title` - The new windows title

  ## Examples

      iex> Desktop.Window.set_title(pid, "New Window Title")
      :ok

  """
  def set_title(pid, title) do
    GenServer.cast(pid, {:set_title, title})
  end

  @doc """
  Iconize or restore the window

    * `pid` - The pid or atom of the Window
    * `restore` - Optional defaults to false whether the
                  window should be restored
  """
  def iconize(pid, iconize \\ true) do
    GenServer.cast(pid, {:iconize, iconize})
  end

  @doc """
  Rebuild the webview. This function is a troubleshooting
  function at this time. On Windows it's sometimes neccesary
  to rebuild the WebView2 frame.

    * `pid` - The pid or atom of the Window

  ## Examples

      iex> Desktop.Window.rebuild_webview(pid)
      :ok

  """
  def rebuild_webview(pid) do
    GenServer.cast(pid, :rebuild_webview)
  end

  @doc """
  Fetch the underlying :wxWebView instance object. Call
  this if you have to use more advanced :wxWebView functions
  directly on the object.

    * `pid` - The pid or atom of the Window

  ## Examples

      iex> :wx.set_env(Desktop.Env.wx_env())
      iex> :wxWebView.isContextMenuEnabled(Desktop.Window.webview(pid))
      false

  """
  def webview(pid) do
    GenServer.call(pid, :webview)
  end

  @doc """
  Fetch the underlying :wxFrame instance object. This represents
  the window which the webview is drawn into.

    * `pid` - The pid or atom of the Window

  ## Examples

      iex> :wx.set_env(Desktop.Env.wx_env())
      iex> :wxWindow.show(Desktop.Window.frame(pid), show: false)
      false

  """
  def frame(pid) do
    GenServer.call(pid, :frame)
  end

  @doc """
  Show a desktop notification

    * `pid` - The pid or atom of the Window

    * `text` - The text content to show in the notification

    * `opts` - Additional notification options

      Valid keys are:

        * `:id` - An id for the notification, this is important if you
          want control, the visibility of the notification. The default
          value when none is provided is `:default`

        * `:type` - One of `:info` `:error` `:warn` these will change
          how the notification will be displayed. The default is `:info`

        * `:title` - An alternative title for the notificaion,
          when none is provided the current window title is used.

        * `:timeout` - A timeout hint specifying how long the notification
          should be displayed.

          Possible values are:

            * `:auto` - This is the default and let's the OS decide

            * `:never` - Indiciates that notification should not be hidden
              automatically

            * ms - A time value in milliseconds, how long the notification
              should be shown

        * `:callback` - A function to be executed when the user clicks on the
          notification.

  ## Examples

      iex> :wx.set_env(Desktop.Env.wx_env())
      iex> :wxWebView.isContextMenuEnabled(Desktop.Window.webview(pid))
      false

  """
  def show_notification(pid, text, opts \\ []) do
    id = Keyword.get(opts, :id, :default)

    type =
      case Keyword.get(opts, :type, :info) do
        :info -> :info
        :error -> :error
        :warn -> :warning
        :warning -> :warning
      end

    title = Keyword.get(opts, :title, nil)

    timeout =
      case Keyword.get(opts, :timeout, :auto) do
        :auto -> -1
        :never -> 0
        ms when is_integer(ms) -> ms
      end

    callback = Keyword.get(opts, :callback, nil)
    GenServer.cast(pid, {:show_notification, text, id, type, title, callback, timeout})
  end

  @doc """
  Quit the application. This forces a quick termination which can
  be helpfull on MacOS/Windows as sometimes the destruction is
  crashing.
  """
  def quit() do
    OS.shutdown()
  end

  require Record

  for tag <- [:wx, :wxCommand, :wxClose] do
    Record.defrecordp(tag, Record.extract(tag, from_lib: "wx/include/wx.hrl"))
  end

  @doc false
  def handle_event(
        wx(event: {:wxTaskBarIcon, :taskbar_left_down}),
        menu = %Window{taskbar: taskbar}
      ) do
    Menu.popup_menu(taskbar)
    {:noreply, menu}
  end

  def handle_event(
        wx(event: {:wxTaskBarIcon, :taskbar_right_down}),
        menu = %Window{taskbar: taskbar}
      ) do
    Menu.popup_menu(taskbar)
    {:noreply, menu}
  end

  def handle_event(
        wx(event: wxClose(type: :close_window)),
        ui = %Window{frame: frame, taskbar: taskbar}
      ) do
    if taskbar == nil do
      :wxFrame.hide(frame)
      {:stop, :normal, ui}
    else
      :wxFrame.hide(frame)
      {:noreply, ui}
    end
  end

  def handle_event(wx(event: {:wxWebView, :webview_newwindow, _, _, _target, url}), ui) do
    :wx_misc.launchDefaultBrowser(url)
    {:noreply, ui}
  end

  def handle_event(wx(obj: obj, event: wxCommand(type: :notification_message_click)), ui) do
    notification(ui, obj, :click)
    {:noreply, ui}
  end

  def handle_event(wx(obj: obj, event: wxCommand(type: :notification_message_dismissed)), ui) do
    notification(ui, obj, :dismiss)
    {:noreply, ui}
  end

  def handle_event(
        wx(obj: obj, event: wxCommand(commandInt: action, type: :notification_message_action)),
        ui
      ) do
    notification(ui, obj, {:action, action})
    {:noreply, ui}
  end

  defp notification(%Window{notifications: noties}, obj, action) do
    case Enum.find(noties, fn {_, {wx_ref, _callback}} -> wx_ref == obj end) do
      nil ->
        Logger.error(
          "Received unhandled notification event #{inspect(obj)}: #{inspect(action)} (#{
            inspect(noties)
          })"
        )

      {_, {_ref, nil}} ->
        :ok

      {_, {_ref, callback}} ->
        spawn(fn -> callback.(action) end)
    end
  end

  @impl true
  @doc false
  def handle_info(:rebuild, ui = %Window{rebuild: rebuild, rebuild_timer: t, webview: webview}) do
    ui =
      if Fallback.webview_can_fix(webview) do
        case rebuild do
          0 ->
            %Window{ui | rebuild: 1}

          1 ->
            :timer.cancel(t)
            %Window{ui | rebuild: :done, webview: Fallback.webview_rebuild(ui)}

          :done ->
            ui
        end
      else
        if rebuild == :done do
          ui
        else
          %Window{ui | rebuild: 0}
        end
      end

    {:noreply, ui}
  end

  @impl true
  @doc false
  def handle_cast({:set_title, title}, ui = %Window{title: old, frame: frame}) do
    if title != old and frame != nil do
      :wxFrame.setTitle(frame, String.to_charlist(title))
    end

    {:noreply, %Window{ui | title: title}}
  end

  @impl true
  @doc false
  def handle_cast({:iconize, iconize}, ui = %Window{frame: frame}) do
    :wxTopLevelWindow.iconize(frame, iconize: iconize)
    {:noreply, ui}
  end

  @impl true
  def handle_cast(:rebuild_webview, ui) do
    {:noreply, %Window{ui | webview: Fallback.webview_rebuild(ui)}}
  end

  @impl true
  def handle_cast(
        {:show_notification, message, id, type, title, callback, timeout},
        ui = %Window{notifications: noties, title: window_title}
      ) do
    {n, _} =
      note =
      case Map.get(noties, id, nil) do
        nil -> {Fallback.notification_new(title || window_title, type), callback}
        {note, _} -> {note, callback}
      end

    Fallback.notification_show(n, message, timeout)
    noties = Map.put(noties, id, note)
    {:noreply, %Window{ui | notifications: noties}}
  end

  @impl true
  def handle_cast({:show, url}, ui = %Window{home_url: home, last_url: last}) do
    new_url = prepare_url(url || last || home)
    Logger.info("Showing #{new_url}")
    Fallback.webview_show(ui, new_url, url == nil)
    {:noreply, %Window{ui | last_url: new_url}}
  end

  @impl true
  @doc false
  def handle_call(:webview, _from, ui = %Window{webview: webview}) do
    {:reply, webview, ui}
  end

  @impl true
  @doc false
  def handle_call(:frame, _from, ui = %Window{frame: frame}) do
    {:reply, frame, ui}
  end

  defp prepare_url(url) do
    query = "k=" <> Desktop.Auth.login_key()

    case url do
      nil -> nil
      fun when is_function(fun) -> append_query(fun.(), query)
      string when is_binary(string) -> append_query(string, query)
    end
  end

  defp append_query(url, query) do
    case URI.parse(url) do
      url = %URI{query: nil} ->
        %URI{url | query: query}

      url = %URI{query: other} ->
        if not String.contains?(other, query) do
          %URI{url | query: other <> "&" <> query}
        else
          url
        end
    end
    |> URI.to_string()
  end
end
