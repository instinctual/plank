CONFIG += console c++17
TEMPLATE = app
TARGET = plank-qt-session-probe
include(../../apps/client/app/streaming/qt/qtsession.pri)
include(../../apps/client/app/streaming/qt/qtvideo.pri)
PKGCONFIG += libplacebo vulkan fontconfig libavcodec libswresample libpipewire-0.3 sdl3
INCLUDEPATH += ../../apps/client/app ../../apps/client/moonlight-common-c/moonlight-common-c/src
QMAKE_RPATHDIR += $$system(pkg-config --variable=libdir libavutil)
QMAKE_RPATHDIR += $$system(pkg-config --variable=libdir sdl3)
QMAKE_LFLAGS += -Wl,--disable-new-dtags
SOURCES += presentercheck.cpp ../../apps/client/app/streaming/audio/renderers/pipewire.cpp ../../apps/client/app/streaming/avsynccontroller.cpp
HEADERS += presentercheck.h
SOURCES += main.cpp precisioncheck.cpp videoprecisioncheck.cpp gpuinteropcheck.cpp softwareinteropcheck.cpp
HEADERS += precisioncheck.h videoprecisioncheck.h gpuinteropcheck.h softwareinteropcheck.h
