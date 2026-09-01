defmodule GiTF.Dashboard.CabinetLayouts do
  @moduledoc """
  Root layout for the Cabinet Console — the Cabinet's OWN chrome, not the
  factory dashboard's. Carries the control-surface design tokens (GiTF
  Control Surface plan §06: cool ground, soft panels, tinted status
  pills, dark icon rail; dark and light designed separately).
  """

  use Phoenix.Component

  import Phoenix.Controller, only: [get_csrf_token: 0]

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={get_csrf_token()} />
        <title>Cabinet</title>
        <style>
          :root{
            --ground:#F4F6F9; --panel:#FFFFFF; --panel-2:#F8FAFC; --line:#E6EAF0; --line-2:#EDF0F4;
            --text:#212832; --text-2:#4E5866; --muted:#8B95A5;
            --accent:#2E7DF7; --accent-ink:#FFFFFF; --accent-soft:#EBF2FE;
            --rail:#101821; --rail-text:#9AA7B8; --rail-on:#FFFFFF; --rail-active:rgba(255,255,255,.08);
            --ok:#1E9E5C; --ok-bg:#E6F6EE; --warn:#B27A17; --warn-bg:#FCF3E3;
            --crit:#C93B3B; --crit-bg:#FCEAEA; --recon:#6B4FD8; --recon-bg:#F0EBFC;
            --off:#7A8594; --off-bg:#EEF1F4;
            --shadow:0 1px 2px rgba(16,24,40,.06),0 1px 3px rgba(16,24,40,.06);
            --mono:"JetBrains Mono",ui-monospace,SFMono-Regular,Menlo,monospace;
            --sans:system-ui,-apple-system,"Segoe UI",Roboto,"Helvetica Neue",Arial,sans-serif;
          }
          @media (prefers-color-scheme: dark){
            :root{
              --ground:#14181E; --panel:#1C2129; --panel-2:#20262F; --line:#2A313B; --line-2:#252C35;
              --text:#E9EDF2; --text-2:#B4BDC9; --muted:#8B95A5;
              --accent:#4C9AFF; --accent-ink:#0E1218; --accent-soft:#1B2C45;
              --rail:#0D1218; --rail-text:#8B98A9; --rail-on:#FFFFFF; --rail-active:rgba(255,255,255,.07);
              --ok:#43C383; --ok-bg:#15291F; --warn:#E0A82E; --warn-bg:#2E2513;
              --crit:#EA6A62; --crit-bg:#321B1B; --recon:#A78BFA; --recon-bg:#241E38;
              --off:#8B95A5; --off-bg:#232933;
              --shadow:0 1px 2px rgba(0,0,0,.3);
            }
          }
          *,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
          html{font-size:14px}
          body{background:var(--ground);color:var(--text);font-family:var(--sans);line-height:1.5;min-height:100vh}
          a{color:var(--accent);text-decoration:none}
          button{font:inherit;color:inherit;background:none;border:0;cursor:pointer;text-align:left}
          button:focus-visible,a:focus-visible{outline:2px solid var(--accent);outline-offset:2px;border-radius:4px}
          .mono{font-family:var(--mono);font-variant-numeric:tabular-nums}
          .muted{color:var(--muted)}
        </style>
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end
end
