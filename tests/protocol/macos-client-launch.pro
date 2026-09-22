QT += core network gui qml
CONFIG += console c++17 link_pkgconfig
PKGCONFIG += openssl
CONFIG -= app_bundle
TEMPLATE = app
TARGET = macos-client-launch
isEmpty(PLANK_CLIENT_SOURCE): error(Set PLANK_CLIENT_SOURCE to the exact clean Client worktree)
isEmpty(PLANK_COMMON_SOURCE): error(Set PLANK_COMMON_SOURCE to its exact common-c worktree)
SOURCES += $$PWD/macos-client-launch.cpp \
    $$PLANK_CLIENT_SOURCE/app/backend/nvhttp.cpp \
    $$PLANK_CLIENT_SOURCE/app/backend/hosttruststore.cpp \
    $$PLANK_CLIENT_SOURCE/app/backend/hosttlsguard.cpp \
    $$PLANK_CLIENT_SOURCE/app/backend/nvaddress.cpp \
    $$PLANK_CLIENT_SOURCE/app/backend/outputtopology.cpp
HEADERS += $$PLANK_CLIENT_SOURCE/app/backend/nvhttp.h
INCLUDEPATH += $$PLANK_CLIENT_SOURCE/app $$PLANK_COMMON_SOURCE/src
QMAKE_CXXFLAGS += -ffunction-sections -fdata-sections -Wall -Wextra -Werror
QMAKE_LFLAGS += -Wl,--gc-sections
