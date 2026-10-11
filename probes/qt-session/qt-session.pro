CONFIG += console c++17
TEMPLATE = app
TARGET = plank-qt-session-probe
include(../../apps/client/app/streaming/qt/qtsession.pri)
SOURCES += main.cpp precisioncheck.cpp
HEADERS += precisioncheck.h
