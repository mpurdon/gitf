defmodule Hive.Web.Layout do
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
        <title>Hive Control Plane</title>
        <script src="https://cdn.tailwindcss.com"></script>
        <style>
          .hive-scrollbar::-webkit-scrollbar { width: 6px; height: 6px; }
          .hive-scrollbar::-webkit-scrollbar-track { background: rgb(31, 41, 55); border-radius: 3px; }
          .hive-scrollbar::-webkit-scrollbar-thumb { background: rgb(75, 85, 99); border-radius: 3px; }
          .hive-scrollbar::-webkit-scrollbar-thumb:hover { background: rgb(107, 114, 128); }
        </style>
      </head>
      <body class="bg-gray-900 text-gray-100 font-mono antialiased">
        <%= @inner_content %>
        <script src="/assets/phoenix.min.js"></script>
        <script src="/assets/phoenix_live_view.min.js"></script>
        <script>
          let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");
          let liveSocket = new window.LiveView.LiveSocket("/live", window.Phoenix.Socket, {
            params: {_csrf_token: csrfToken}
          });
          liveSocket.connect();
        </script>
      </body>
    </html>
    """
  end
end
