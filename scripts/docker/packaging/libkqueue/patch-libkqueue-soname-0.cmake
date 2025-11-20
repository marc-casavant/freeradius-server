# This snippet is appended to libkqueue's CMakeLists.txt
# after the 'kqueue' library target is defined.
# It overrides VERSION/SOVERSION so the resulting shared
# library installs as libkqueue.so.0 (stable ABI anchor).
get_target_property(_type kqueue TYPE)
if(_type)
  # VERSION 0.0.0 → internal library version
  # SOVERSION 0   → SONAME becomes libkqueue.so.0
  set_target_properties(kqueue PROPERTIES
    VERSION 0.0.0
    SOVERSION 0)
endif()