QT += core network gui qml
CONFIG += console c++17 link_pkgconfig
CONFIG -= app_bundle
TEMPLATE = app
TARGET = macos-installed-client
isEmpty(PLANK_CLIENT_SOURCE): error(Set PLANK_CLIENT_SOURCE)
isEmpty(PLANK_COMMON_SOURCE): error(Set PLANK_COMMON_SOURCE)
isEmpty(PLANK_TRANSPORT_LIBRARY): error(Set the retained transport archive)
SOURCES += $$PWD/macos-installed-client.cpp \
    $$PLANK_CLIENT_SOURCE/app/backend/nvhttp.cpp \
    $$PLANK_CLIENT_SOURCE/app/backend/hosttruststore.cpp \
    $$PLANK_CLIENT_SOURCE/app/backend/hosttlsguard.cpp \
    $$PLANK_CLIENT_SOURCE/app/backend/nvaddress.cpp \
    $$PLANK_CLIENT_SOURCE/app/backend/outputtopology.cpp
HEADERS += $$PLANK_CLIENT_SOURCE/app/backend/nvhttp.h
INCLUDEPATH += $$PLANK_CLIENT_SOURCE/app $$PLANK_COMMON_SOURCE/src $$PWD/../../protocol/plank-transport/include
PKGCONFIG += libavcodec libavutil libswresample opus openssl
LIBS += $$PLANK_TRANSPORT_LIBRARY -lpthread -ldl -lm
QMAKE_CXXFLAGS += -ffunction-sections -fdata-sections -Wall -Wextra -Werror
QMAKE_LFLAGS += -Wl,--gc-sections
