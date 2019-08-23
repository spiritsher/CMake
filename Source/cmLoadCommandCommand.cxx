/* Distributed under the OSI-approved BSD 3-Clause License.  See accompanying
   file Copyright.txt or https://cmake.org/licensing for details.  */
#include "cmLoadCommandCommand.h"

#include <signal.h>

#include <sstream>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <utility>

#include "cm_memory.hxx"

#include "cmCPluginAPI.cxx"
#include "cmCPluginAPI.h"
#include "cmDynamicLoader.h"
#include "cmMakefile.h"
#include "cmState.h"
#include "cmStringAlgorithms.h"
#include "cmSystemTools.h"

class cmExecutionStatus;

#ifdef __QNX__
#  include <malloc.h> /* for malloc/free on QNX */
#endif

namespace {

const char* LastName = nullptr;

extern "C" void TrapsForSignals(int sig)
{
  fprintf(stderr, "CMake loaded command %s crashed with signal: %d.\n",
          LastName, sig);
}

struct SignalHandlerGuard
{
  explicit SignalHandlerGuard(const char* name)
  {
    LastName = name != nullptr ? name : "????";

    signal(SIGSEGV, TrapsForSignals);
#ifdef SIGBUS
    signal(SIGBUS, TrapsForSignals);
#endif
    signal(SIGILL, TrapsForSignals);
  }

  ~SignalHandlerGuard()
  {
    signal(SIGSEGV, nullptr);
#ifdef SIGBUS
    signal(SIGBUS, nullptr);
#endif
    signal(SIGILL, nullptr);
  }

  SignalHandlerGuard(SignalHandlerGuard const&) = delete;
  SignalHandlerGuard& operator=(SignalHandlerGuard const&) = delete;
};

struct LoadedCommandImpl : cmLoadedCommandInfo
{
  explicit LoadedCommandImpl(CM_INIT_FUNCTION init)
    : cmLoadedCommandInfo{ 0,       0,       &cmStaticCAPI, 0,
                           nullptr, nullptr, nullptr,       nullptr,
                           nullptr, nullptr, nullptr,       nullptr }
  {
    init(this);
  }

  ~LoadedCommandImpl()
  {
    if (this->Destructor) {
      SignalHandlerGuard guard(this->Name);
      this->Destructor(this);
    }
    if (this->Error != nullptr) {
      free(this->Error);
    }
  }

  LoadedCommandImpl(LoadedCommandImpl const&) = delete;
  LoadedCommandImpl& operator=(LoadedCommandImpl const&) = delete;

  int DoInitialPass(cmMakefile* mf, int argc, char* argv[])
  {
    SignalHandlerGuard guard(this->Name);
    return this->InitialPass(this, mf, argc, argv);
  }

  void DoFinalPass(cmMakefile* mf)
  {
    SignalHandlerGuard guard(this->Name);
    this->FinalPass(this, mf);
  }
};

// a class for loadabple commands
class cmLoadedCommand : public cmCommand
{
public:
  cmLoadedCommand() = default;
  explicit cmLoadedCommand(CM_INIT_FUNCTION init)
    : Impl(std::make_shared<LoadedCommandImpl>(init))
  {
  }

  /**
   * This is a virtual constructor for the command.
   */
  std::unique_ptr<cmCommand> Clone() override
  {
    auto newC = cm::make_unique<cmLoadedCommand>();
    // we must copy when we clone
    newC->Impl = this->Impl;
    return std::unique_ptr<cmCommand>(std::move(newC));
  }

  /**
   * This is called when the command is first encountered in
   * the CMakeLists.txt file.
   */
  bool InitialPass(std::vector<std::string> const& args,
                   cmExecutionStatus&) override;

private:
  std::shared_ptr<LoadedCommandImpl> Impl;
};

bool cmLoadedCommand::InitialPass(std::vector<std::string> const& args,
                                  cmExecutionStatus&)
{
  if (!this->Impl->InitialPass) {
    return true;
  }

  // clear the error string
  if (this->Impl->Error) {
    free(this->Impl->Error);
  }

  // create argc and argv and then invoke the command
  int argc = static_cast<int>(args.size());
  char** argv = nullptr;
  if (argc) {
    argv = static_cast<char**>(malloc(argc * sizeof(char*)));
  }
  int i;
  for (i = 0; i < argc; ++i) {
    argv[i] = strdup(args[i].c_str());
  }
  int result = this->Impl->DoInitialPass(this->Makefile, argc, argv);
  cmFreeArguments(argc, argv);

  if (result) {
    if (this->Impl->FinalPass) {
      auto impl = this->Impl;
      this->Makefile->AddFinalAction(
        [impl](cmMakefile& makefile) { impl->DoFinalPass(&makefile); });
    }
    return true;
  }

  /* Initial Pass must have failed so set the error string */
  if (this->Impl->Error) {
    this->SetError(this->Impl->Error);
  }
  return false;
}

} // namespace

// cmLoadCommandCommand
bool cmLoadCommandCommand::InitialPass(std::vector<std::string> const& args,
                                       cmExecutionStatus&)
{
  if (args.empty()) {
    return true;
  }

  // Construct a variable to report what file was loaded, if any.
  // Start by removing the definition in case of failure.
  std::string reportVar = cmStrCat("CMAKE_LOADED_COMMAND_", args[0]);
  this->Makefile->RemoveDefinition(reportVar);

  // the file must exist
  std::string moduleName = cmStrCat(
    this->Makefile->GetRequiredDefinition("CMAKE_SHARED_MODULE_PREFIX"), "cm",
    args[0],
    this->Makefile->GetRequiredDefinition("CMAKE_SHARED_MODULE_SUFFIX"));

  // search for the file
  std::vector<std::string> path;
  for (unsigned int j = 1; j < args.size(); j++) {
    // expand variables
    std::string exp = args[j];
    cmSystemTools::ExpandRegistryValues(exp);

    // Glob the entry in case of wildcards.
    cmSystemTools::GlobDirs(exp, path);
  }

  // Try to find the program.
  std::string fullPath = cmSystemTools::FindFile(moduleName, path);
  if (fullPath.empty()) {
    std::ostringstream e;
    e << "Attempt to load command failed from file \"" << moduleName << "\"";
    this->SetError(e.str());
    return false;
  }

  // try loading the shared library / dll
  cmsys::DynamicLoader::LibraryHandle lib =
    cmDynamicLoader::OpenLibrary(fullPath.c_str());
  if (!lib) {
    std::string err =
      cmStrCat("Attempt to load the library ", fullPath, " failed.");
    const char* error = cmsys::DynamicLoader::LastError();
    if (error) {
      err += " Additional error info is:\n";
      err += error;
    }
    this->SetError(err);
    return false;
  }

  // Report what file was loaded for this command.
  this->Makefile->AddDefinition(reportVar, fullPath);

  // find the init function
  std::string initFuncName = args[0] + "Init";
  CM_INIT_FUNCTION initFunction = reinterpret_cast<CM_INIT_FUNCTION>(
    cmsys::DynamicLoader::GetSymbolAddress(lib, initFuncName));
  if (!initFunction) {
    initFuncName = cmStrCat('_', args[0], "Init");
    initFunction = reinterpret_cast<CM_INIT_FUNCTION>(
      cmsys::DynamicLoader::GetSymbolAddress(lib, initFuncName));
  }
  // if the symbol is found call it to set the name on the
  // function blocker
  if (initFunction) {
    this->Makefile->GetState()->AddScriptedCommand(
      args[0],
      cmLegacyCommandWrapper(cm::make_unique<cmLoadedCommand>(initFunction)));
    return true;
  }
  this->SetError("Attempt to load command failed. "
                 "No init function found.");
  return false;
}
