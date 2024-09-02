import unittest
import potato
import sdl2_nim/sdl
import std/strutils


const
  Title = "SDL2 App"
  ScreenW = 640 # Window width
  ScreenH = 480 # Window height
  WindowFlags = 0
  RendererFlags = sdl.RendererAccelerated or sdl.RendererPresentVsync


type
  App = object
    window*: sdl.Window # Window pointer
    renderer*: sdl.Renderer # Rendering state pointer


# Initialization sequence
proc init(app: var App): bool =
  # Init SDL
  if sdl.init(sdl.InitVideo) != 0:
    echo "ERROR: Can't initialize SDL: ", sdl.getError()
    return false

  # Create window
  app.window = sdl.createWindow(
    Title,
    sdl.WindowPosUndefined,
    sdl.WindowPosUndefined,
    ScreenW,
    ScreenH,
    WindowFlags)
  if app.window == nil:
    echo "ERROR: Can't create window: ", sdl.getError()
    return false

  # Create renderer
  app.renderer = sdl.createRenderer(app.window, -1, RendererFlags)
  if app.renderer == nil:
    echo "ERROR: Can't create renderer: ", sdl.getError()
    return false

  # Set draw color
  if app.renderer.setRenderDrawColor(0xFF, 0xFF, 0xFF, 0xFF) != 0:
    echo "ERROR: Can't set draw color: ", sdl.getError()
    return false


  echo "SDL initialized successfully"
  return true


# Shutdown sequence
proc exit(app: var App) =
  app.renderer.destroyRenderer()
  app.window.destroyWindow()
  sdl.quit()
  echo "SDL shutdown completed"


########
# MAIN #
########


var app {.persistent.} = App(window: nil, renderer: nil)

var rect {.persistent.} = Rect(x: 0, y: 0, w: 100, h:100)


proc potatoMain() {.exportc, dynlib.}=
  #app.someProc()

  if app.window != nil or init(app):
    # Clear screen with draw color
    discard app.renderer.setRenderDrawColor(0, 0, 0, 255)
    if app.renderer.renderClear() != 0:
      echo "Warning: Can't clear screen: ", sdl.getError()
    discard app.renderer.setRenderDrawColor(0, 255, 127, 255)
    discard app.renderer.renderFillRect(rect.addr)
    rect.x += 4
    rect.y += 2
    var w, h: cint
    app.window.getWindowSize(w.addr, h.addr)
    if rect.x > w:
      rect.x = 0
    if rect.y > h:
      rect.y = 0

    var evt: Event
    while pollEvent(addr evt) != 0:
      case evt.kind
      of Keydown:
        if evt.key.keysym.sym == K_F11:
          potatoCompileIt()

      of WindowEvent:
        if evt.window.event.WindowEventID == WindowEventClose:
          app.exit()
          potatoQuit()
      else:
        discard
    # Update renderer
    app.renderer.renderPresent()

