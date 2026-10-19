CONFIG += console c++17
TEMPLATE = app
TARGET = plank-qt-session-probe
include(../../apps/client/app/streaming/qt/qtsession.pri)
include(../../apps/client/app/streaming/qt/qtvideo.pri)
QMAKE_RPATHDIR += $$system(pkg-config --variable=libdir libavutil)
SOURCES += main.cpp precisioncheck.cpp videoprecisioncheck.cpp
HEADERS += precisioncheck.h videoprecisioncheck.h
