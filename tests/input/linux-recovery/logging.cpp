// Standalone test logging; production input implementations are linked intact.
#include "src/logging.h"

boost::log::sources::severity_logger<int> verbose, debug, info, warning, error, fatal, tests;
