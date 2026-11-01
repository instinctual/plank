QT += core
CONFIG += console c++17 link_pkgconfig
CONFIG -= app_bundle
TEMPLATE = app
TARGET = client-microphone
isEmpty(PLANK_CLIENT_SOURCE): error(Set PLANK_CLIENT_SOURCE)
PKGCONFIG += opus
DEFINES += PLANK_TRANSPORT
SOURCES += $$PWD/client-microphone.cpp $$PLANK_CLIENT_SOURCE/app/streaming/audio/microphone.cpp
INCLUDEPATH += $$PLANK_CLIENT_SOURCE/app/streaming/audio $$PWD/../../protocol/plank-transport/include
QMAKE_CXXFLAGS += -Wall -Wextra -Werror

equals(PLANK_TIMED_CAPTURE_TEST, 1): DEFINES += PLANK_TIMED_CAPTURE_TEST
