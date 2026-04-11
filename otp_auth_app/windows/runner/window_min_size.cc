#include <flutter/flutter.h>
#include <windows.h>
#include <memory>

// Method channel handler for setting minimum size
class WindowMethodHandler {
 public:
  static void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
    
    if (method_call.method_name().compare("setMinimumSize") == 0) {
      const auto* arguments = std::get_if<flutter::EncodableMap>(method_call.arguments());
      if (arguments) {
        auto width_it = arguments->find(flutter::EncodableValue("width"));
        auto height_it = arguments->find(flutter::EncodableValue("height"));
        
        if (width_it != arguments->end() && height_it != arguments->end()) {
          double width = std::get<double>(width_it->second);
          double height = std::get<double>(height_it->second);
          
          HWND hwnd = GetActiveWindow();
          RECT rect;
          GetWindowRect(hwnd, &rect);
          
          // Set minimum tracking size
          SetWindowPos(hwnd, NULL, rect.left, rect.top, 
                       max(rect.right - rect.left, (int)width),
                       max(rect.bottom - rect.top, (int)height),
                       SWP_NOZORDER);
          
          result->Success(flutter::EncodableValue(true));
          return;
        }
      }
      result->Success(flutter::EncodableValue(false));
    } else {
      result->NotImplemented();
    }
  }
};