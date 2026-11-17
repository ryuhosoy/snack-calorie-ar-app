import ExpoModulesCore

public final class SnackARModule: Module {
  public func definition() -> ModuleDefinition {
    Name("SnackAR")

    View(SnackARView.self) {
      /// true にすると検出した領域の枠を表示（検証用）
      Prop("debug") { (view: SnackARView, debug: Bool) in
        view.debug = debug
      }
    }
  }
}
