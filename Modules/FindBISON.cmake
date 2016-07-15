#.rst:
# FindBISON
# ---------
#
# Find ``bison`` executable and provide a macro to generate custom build rules.
#
# The module defines the following variables:
#
# ``BISON_EXECUTABLE``
#   path to the ``bison`` program
#
# ``BISON_VERSION``
#   version of ``bison``
#
# ``BISON_FOUND``
#   true if the program was found
#
# The minimum required version of ``bison`` can be specified using the
# standard CMake syntax, e.g.  ``find_package(BISON 2.1.3)``.
#
# If ``bison`` is found, the module defines the macro::
#
#   BISON_TARGET(<Name> <YaccInput> <CodeOutput>
#                [COMPILE_FLAGS <flags>]
#                [DEFINES_FILE <file>]
#                [VERBOSE [<file>]]
#                [REPORT_FILE <file>]
#                )
#
# which will create a custom rule to generate a parser.  ``<YaccInput>`` is
# the path to a yacc file.  ``<CodeOutput>`` is the name of the source file
# generated by bison.  A header file is also be generated, and contains
# the token list.
#
# The options are:
#
# ``COMPILE_FLAGS <flags>``
#   Specify flags to be added to the ``bison`` command line.
#
# ``DEFINES_FILE <file>``
#   Specify a non-default header ``<file>`` to be generated by ``bison``.
#
# ``VERBOSE [<file>]``
#   Tell ``bison`` to write a report file of the grammar and parser.
#   If ``<file>`` is given, it specifies path the report file is copied to.
#   ``[<file>]`` is left for backward compatibility of this module.
#   Use ``VERBOSE REPORT_FILE <file>``.
#
# ``REPORT_FILE <file>``
#   Specify a non-default report ``<file>``, if generated.
#
# The macro defines the following variables:
#
# ``BISON_<Name>_DEFINED``
#   true is the macro ran successfully
#
# ``BISON_<Name>_INPUT``
#   The input source file, an alias for <YaccInput>
#
# ``BISON_<Name>_OUTPUT_SOURCE``
#   The source file generated by bison
#
# ``BISON_<Name>_OUTPUT_HEADER``
#   The header file generated by bison
#
# ``BISON_<Name>_OUTPUTS``
#   All files generated by bison including the source, the header and the report
#
# ``BISON_<Name>_COMPILE_FLAGS``
#   Options used in the ``bison`` command line
#
# Example usage:
#
# .. code-block:: cmake
#
#   find_package(BISON)
#   BISON_TARGET(MyParser parser.y ${CMAKE_CURRENT_BINARY_DIR}/parser.cpp
#                DEFINES_FILE ${CMAKE_CURRENT_BINARY_DIR}/parser.h)
#   add_executable(Foo main.cpp ${BISON_MyParser_OUTPUTS})

#=============================================================================
# Copyright 2009 Kitware, Inc.
# Copyright 2006 Tristan Carel
#
# Distributed under the OSI-approved BSD License (the "License");
# see accompanying file Copyright.txt for details.
#
# This software is distributed WITHOUT ANY WARRANTY; without even the
# implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
# See the License for more information.
#=============================================================================
# (To distribute this file outside of CMake, substitute the full
#  License text for the above reference.)

find_program(BISON_EXECUTABLE NAMES bison win_bison DOC "path to the bison executable")
mark_as_advanced(BISON_EXECUTABLE)

include(CMakeParseArguments)

if(BISON_EXECUTABLE)
  # the bison commands should be executed with the C locale, otherwise
  # the message (which are parsed) may be translated
  set(_Bison_SAVED_LC_ALL "$ENV{LC_ALL}")
  set(ENV{LC_ALL} C)

  execute_process(COMMAND ${BISON_EXECUTABLE} --version
    OUTPUT_VARIABLE BISON_version_output
    ERROR_VARIABLE BISON_version_error
    RESULT_VARIABLE BISON_version_result
    OUTPUT_STRIP_TRAILING_WHITESPACE)

  set(ENV{LC_ALL} ${_Bison_SAVED_LC_ALL})

  if(NOT ${BISON_version_result} EQUAL 0)
    message(SEND_ERROR "Command \"${BISON_EXECUTABLE} --version\" failed with output:\n${BISON_version_error}")
  else()
    # Bison++
    if("${BISON_version_output}" MATCHES "^bison\\+\\+ Version ([^,]+)")
      set(BISON_VERSION "${CMAKE_MATCH_1}")
    # GNU Bison
    elseif("${BISON_version_output}" MATCHES "^bison \\(GNU Bison\\) ([^\n]+)\n")
      set(BISON_VERSION "${CMAKE_MATCH_1}")
    elseif("${BISON_version_output}" MATCHES "^GNU Bison (version )?([^\n]+)")
      set(BISON_VERSION "${CMAKE_MATCH_2}")
    endif()
  endif()

  # internal macro
  macro(BISON_TARGET_set_verbose_file BisonOutput)
    get_filename_component(BISON_TARGET_output_path "${BisonOutput}" PATH)
    get_filename_component(BISON_TARGET_output_name "${BisonOutput}" NAME_WE)
    set(BISON_TARGET_verbose_file
      "${BISON_TARGET_output_path}/${BISON_TARGET_output_name}.output")
  endmacro()

  # internal macro
  macro(BISON_TARGET_option_verbose Name BisonOutput filename)
    list(APPEND BISON_TARGET_cmdopt "--verbose")
    list(APPEND BISON_TARGET_extraoutputs
      "${BISON_TARGET_verbose_file}")
    if (NOT "${filename}" STREQUAL "")
      add_custom_command(OUTPUT ${filename}
        COMMAND ${CMAKE_COMMAND} -E copy
        "${BISON_TARGET_verbose_file}"
        "${filename}"
        VERBATIM
        DEPENDS
        "${BISON_TARGET_verbose_file}"
        COMMENT "[BISON][${Name}] Copying bison verbose table to ${filename}"
        WORKING_DIRECTORY ${CMAKE_SOURCE_DIR})
      set(BISON_${Name}_VERBOSE_FILE ${filename})
      list(APPEND BISON_TARGET_extraoutputs
        "${filename}")
    endif()
  endmacro()

  # internal macro
  macro(BISON_TARGET_option_extraopts Options)
    set(BISON_TARGET_extraopts "${Options}")
    separate_arguments(BISON_TARGET_extraopts)
    list(APPEND BISON_TARGET_cmdopt ${BISON_TARGET_extraopts})
  endmacro()

  # internal macro
  macro(BISON_TARGET_option_defines Header)
    set(BISON_TARGET_output_header "${Header}")
    list(APPEND BISON_TARGET_cmdopt "--defines=${BISON_TARGET_output_header}")
  endmacro()

  # internal macro
  macro(BISON_TARGET_option_report_file ReportFile)
    set(BISON_TARGET_verbose_file "${ReportFile}")
    list(APPEND BISON_TARGET_cmdopt "--report-file=${BISON_TARGET_verbose_file}")
  endmacro()

  #============================================================
  # BISON_TARGET (public macro)
  #============================================================
  #
  macro(BISON_TARGET Name BisonInput BisonOutput)
    set(BISON_TARGET_output_header "")
    set(BISON_TARGET_cmdopt "")
    set(BISON_TARGET_outputs "${BisonOutput}")
    set(BISON_TARGET_extraoutputs "")
    BISON_TARGET_set_verbose_file("${BisonOutput}")

    # Parsing parameters
    set(BISON_TARGET_PARAM_OPTIONS
      )
    set(BISON_TARGET_PARAM_ONE_VALUE_KEYWORDS
      COMPILE_FLAGS
      DEFINES_FILE
      REPORT_FILE
      )
    set(BISON_TARGET_PARAM_MULTI_VALUE_KEYWORDS
      VERBOSE
      )
    cmake_parse_arguments(
        BISON_TARGET_ARG
        "${BISON_TARGET_PARAM_OPTIONS}"
        "${BISON_TARGET_PARAM_ONE_VALUE_KEYWORDS}"
        "${BISON_TARGET_PARAM_MULTI_VALUE_KEYWORDS}"
        ${ARGN}
    )

    if(NOT "${BISON_TARGET_ARG_UNPARSED_ARGUMENTS}" STREQUAL "")
      message(SEND_ERROR "Usage")
    elseif("${BISON_TARGET_ARG_VERBOSE}" MATCHES ";")
      # [VERBOSE [<file>] hack: <file> is non-multi value by usage
      message(SEND_ERROR "Usage")
    else()
      if(NOT "${BISON_TARGET_ARG_COMPILE_FLAGS}" STREQUAL "")
        BISON_TARGET_option_extraopts("${BISON_TARGET_ARG_COMPILE_FLAGS}")
      endif()
      if(NOT "${BISON_TARGET_ARG_DEFINES_FILE}" STREQUAL "")
        BISON_TARGET_option_defines("${BISON_TARGET_ARG_DEFINES_FILE}")
      endif()
      if(NOT "${BISON_TARGET_ARG_REPORT_FILE}" STREQUAL "")
        BISON_TARGET_option_report_file("${BISON_TARGET_ARG_REPORT_FILE}")
      endif()
      if(NOT "${BISON_TARGET_ARG_VERBOSE}" STREQUAL "")
        BISON_TARGET_option_verbose(${Name} ${BisonOutput} "${BISON_TARGET_ARG_VERBOSE}")
      else()
        # [VERBOSE [<file>]] is used with no argument or is not used
        set(BISON_TARGET_args "${ARGN}")
        list(FIND BISON_TARGET_args "VERBOSE" BISON_TARGET_args_indexof_verbose)
        if(${BISON_TARGET_args_indexof_verbose} GREATER -1)
          # VERBOSE is used without <file>
          BISON_TARGET_option_verbose(${Name} ${BisonOutput} "")
        endif()
      endif()

      if("${BISON_TARGET_output_header}" STREQUAL "")
        # Header's name generated by bison (see option -d)
        list(APPEND BISON_TARGET_cmdopt "-d")
        string(REGEX REPLACE "^(.*)(\\.[^.]*)$" "\\2" _fileext "${BisonOutput}")
        string(REPLACE "c" "h" _fileext ${_fileext})
        string(REGEX REPLACE "^(.*)(\\.[^.]*)$" "\\1${_fileext}"
            BISON_TARGET_output_header "${BisonOutput}")
      endif()
      list(APPEND BISON_TARGET_outputs "${BISON_TARGET_output_header}")

      add_custom_command(OUTPUT ${BISON_TARGET_outputs}
        ${BISON_TARGET_verbose_file}
        COMMAND ${BISON_EXECUTABLE} ${BISON_TARGET_cmdopt} -o ${BisonOutput} ${BisonInput}
        VERBATIM
        DEPENDS ${BisonInput}
        COMMENT "[BISON][${Name}] Building parser with bison ${BISON_VERSION}"
        WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR})

      # define target variables
      set(BISON_${Name}_DEFINED TRUE)
      set(BISON_${Name}_INPUT ${BisonInput})
      set(BISON_${Name}_OUTPUTS ${BISON_TARGET_outputs} ${BISON_TARGET_extraoutputs})
      set(BISON_${Name}_COMPILE_FLAGS ${BISON_TARGET_cmdopt})
      set(BISON_${Name}_OUTPUT_SOURCE "${BisonOutput}")
      set(BISON_${Name}_OUTPUT_HEADER "${BISON_TARGET_output_header}")

    endif()
  endmacro()
  #
  #============================================================

endif()

include(${CMAKE_CURRENT_LIST_DIR}/FindPackageHandleStandardArgs.cmake)
FIND_PACKAGE_HANDLE_STANDARD_ARGS(BISON REQUIRED_VARS  BISON_EXECUTABLE
                                        VERSION_VAR BISON_VERSION)

# FindBISON.cmake ends here
