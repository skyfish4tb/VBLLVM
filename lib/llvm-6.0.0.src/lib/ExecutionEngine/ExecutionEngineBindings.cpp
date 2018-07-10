//===-- ExecutionEngineBindings.cpp - C bindings for EEs ------------------===//
//
//                     The LLVM Compiler Infrastructure
//
// This file is distributed under the University of Illinois Open Source
// License. See LICENSE.TXT for details.
//
//===----------------------------------------------------------------------===//
//
// This file defines the C bindings for the ExecutionEngine library.
//
//===----------------------------------------------------------------------===//

#include "llvm-c/ExecutionEngine.h"
#include "llvm/ExecutionEngine/ExecutionEngine.h"
#include "llvm/ExecutionEngine/GenericValue.h"
#include "llvm/ExecutionEngine/RTDyldMemoryManager.h"
#include "llvm/IR/DerivedTypes.h"
#include "llvm/IR/Module.h"
#include "llvm/Support/CodeGenCWrappers.h"
#include "llvm/Support/ErrorHandling.h"
#include "llvm/Target/TargetOptions.h"
#include <cstring>

using namespace llvm;

#define DEBUG_TYPE "jit"

// Wrapping the C bindings types.
DEFINE_SIMPLE_CONVERSION_FUNCTIONS(GenericValue, LLVMGenericValueRef)


static LLVMTargetMachineRef wrap(const TargetMachine *P) {
  return
  reinterpret_cast<LLVMTargetMachineRef>(const_cast<TargetMachine*>(P));
}

/*===-- Operations on generic values --------------------------------------===*/

LLVMGenericValueRef LLVM_STDCALL LLVMCreateGenericValueOfInt(LLVMTypeRef Ty,
                                                unsigned long long N,
                                                LLVMBool IsSigned) {
  GenericValue *GenVal = new GenericValue();
  GenVal->IntVal = APInt(unwrap<IntegerType>(Ty)->getBitWidth(), N, IsSigned);
  return wrap(GenVal);
}

LLVMGenericValueRef LLVM_STDCALL LLVMCreateGenericValueOfPointer(void *P) {
  GenericValue *GenVal = new GenericValue();
  GenVal->PointerVal = P;
  return wrap(GenVal);
}

LLVMGenericValueRef LLVM_STDCALL LLVMCreateGenericValueOfFloat(LLVMTypeRef TyRef, double N) {
  GenericValue *GenVal = new GenericValue();
  switch (unwrap(TyRef)->getTypeID()) {
  case Type::FloatTyID:
    GenVal->FloatVal = N;
    break;
  case Type::DoubleTyID:
    GenVal->DoubleVal = N;
    break;
  default:
    llvm_unreachable("LLVMGenericValueToFloat supports only float and double.");
  }
  return wrap(GenVal);
}

unsigned LLVM_STDCALL LLVMGenericValueIntWidth(LLVMGenericValueRef GenValRef) {
  return unwrap(GenValRef)->IntVal.getBitWidth();
}

unsigned long long LLVM_STDCALL LLVMGenericValueToInt(LLVMGenericValueRef GenValRef,
                                         LLVMBool IsSigned) {
  GenericValue *GenVal = unwrap(GenValRef);
  if (IsSigned)
    return GenVal->IntVal.getSExtValue();
  else
    return GenVal->IntVal.getZExtValue();
}

void *LLVM_STDCALL LLVMGenericValueToPointer(LLVMGenericValueRef GenVal) {
  return unwrap(GenVal)->PointerVal;
}

double LLVM_STDCALL LLVMGenericValueToFloat(LLVMTypeRef TyRef, LLVMGenericValueRef GenVal) {
  switch (unwrap(TyRef)->getTypeID()) {
  case Type::FloatTyID:
    return unwrap(GenVal)->FloatVal;
  case Type::DoubleTyID:
    return unwrap(GenVal)->DoubleVal;
  default:
    llvm_unreachable("LLVMGenericValueToFloat supports only float and double.");
  }
}

void LLVM_STDCALL LLVMDisposeGenericValue(LLVMGenericValueRef GenVal) {
  delete unwrap(GenVal);
}

/*===-- Operations on execution engines -----------------------------------===*/

LLVMBool LLVM_STDCALL LLVMCreateExecutionEngineForModule(LLVMExecutionEngineRef *OutEE,
                                            LLVMModuleRef M,
                                            char **OutError) {
  std::string Error;
  EngineBuilder builder(std::unique_ptr<Module>(unwrap(M)));
  builder.setEngineKind(EngineKind::Either)
         .setErrorStr(&Error);
  if (ExecutionEngine *EE = builder.create()){
    *OutEE = wrap(EE);
    return 0;
  }
  *OutError = strdup(Error.c_str());
  return 1;
}

LLVMBool LLVM_STDCALL LLVMCreateInterpreterForModule(LLVMExecutionEngineRef *OutInterp,
                                        LLVMModuleRef M,
                                        char **OutError) {
  std::string Error;
  EngineBuilder builder(std::unique_ptr<Module>(unwrap(M)));
  builder.setEngineKind(EngineKind::Interpreter)
         .setErrorStr(&Error);
  if (ExecutionEngine *Interp = builder.create()) {
    *OutInterp = wrap(Interp);
    return 0;
  }
  *OutError = strdup(Error.c_str());
  return 1;
}

LLVMBool LLVM_STDCALL LLVMCreateJITCompilerForModule(LLVMExecutionEngineRef *OutJIT,
                                        LLVMModuleRef M,
                                        unsigned OptLevel,
                                        char **OutError) {
  std::string Error;
  EngineBuilder builder(std::unique_ptr<Module>(unwrap(M)));
  builder.setEngineKind(EngineKind::JIT)
         .setErrorStr(&Error)
         .setOptLevel((CodeGenOpt::Level)OptLevel);
  if (ExecutionEngine *JIT = builder.create()) {
    *OutJIT = wrap(JIT);
    return 0;
  }
  *OutError = strdup(Error.c_str());
  return 1;
}

void LLVM_STDCALL LLVMInitializeMCJITCompilerOptions(LLVMMCJITCompilerOptions *PassedOptions,
                                        size_t SizeOfPassedOptions) {
  LLVMMCJITCompilerOptions options;
  memset(&options, 0, sizeof(options)); // Most fields are zero by default.
  options.CodeModel = LLVMCodeModelJITDefault;
  
  memcpy(PassedOptions, &options,
         std::min(sizeof(options), SizeOfPassedOptions));
}

LLVMBool LLVM_STDCALL LLVMCreateMCJITCompilerForModule(
    LLVMExecutionEngineRef *OutJIT, LLVMModuleRef M,
    LLVMMCJITCompilerOptions *PassedOptions, size_t SizeOfPassedOptions,
    char **OutError) {
  LLVMMCJITCompilerOptions options;
  // If the user passed a larger sized options struct, then they were compiled
  // against a newer LLVM. Tell them that something is wrong.
  if (SizeOfPassedOptions > sizeof(options)) {
    *OutError = strdup(
      "Refusing to use options struct that is larger than my own; assuming "
      "LLVM library mismatch.");
    return 1;
  }
  
  // Defend against the user having an old version of the API by ensuring that
  // any fields they didn't see are cleared. We must defend against fields being
  // set to the bitwise equivalent of zero, and assume that this means "do the
  // default" as if that option hadn't been available.
  LLVMInitializeMCJITCompilerOptions(&options, sizeof(options));
  memcpy(&options, PassedOptions, SizeOfPassedOptions);
  
  TargetOptions targetOptions;
  targetOptions.EnableFastISel = options.EnableFastISel;
  std::unique_ptr<Module> Mod(unwrap(M));

  if (Mod)
    // Set function attribute "no-frame-pointer-elim" based on
    // NoFramePointerElim.
    for (auto &F : *Mod) {
      auto Attrs = F.getAttributes();
      StringRef Value(options.NoFramePointerElim ? "true" : "false");
      Attrs = Attrs.addAttribute(F.getContext(), AttributeList::FunctionIndex,
                                 "no-frame-pointer-elim", Value);
      F.setAttributes(Attrs);
    }

  std::string Error;
  EngineBuilder builder(std::move(Mod));
  builder.setEngineKind(EngineKind::JIT)
         .setErrorStr(&Error)
         .setOptLevel((CodeGenOpt::Level)options.OptLevel)
         .setTargetOptions(targetOptions);
  bool JIT;
  if (Optional<CodeModel::Model> CM = unwrap(options.CodeModel, JIT))
    builder.setCodeModel(*CM);
  if (options.MCJMM)
    builder.setMCJITMemoryManager(
      std::unique_ptr<RTDyldMemoryManager>(unwrap(options.MCJMM)));
  if (ExecutionEngine *JIT = builder.create()) {
    *OutJIT = wrap(JIT);
    return 0;
  }
  *OutError = strdup(Error.c_str());
  return 1;
}

void LLVM_STDCALL LLVMDisposeExecutionEngine(LLVMExecutionEngineRef EE) {
  delete unwrap(EE);
}

void LLVM_STDCALL LLVMRunStaticConstructors(LLVMExecutionEngineRef EE) {
  unwrap(EE)->finalizeObject();
  unwrap(EE)->runStaticConstructorsDestructors(false);
}

void LLVM_STDCALL LLVMRunStaticDestructors(LLVMExecutionEngineRef EE) {
  unwrap(EE)->finalizeObject();
  unwrap(EE)->runStaticConstructorsDestructors(true);
}

int LLVM_STDCALL LLVMRunFunctionAsMain(LLVMExecutionEngineRef EE, LLVMValueRef F,
                          unsigned ArgC, const char * const *ArgV,
                          const char * const *EnvP) {
  unwrap(EE)->finalizeObject();

  std::vector<std::string> ArgVec(ArgV, ArgV + ArgC);
  return unwrap(EE)->runFunctionAsMain(unwrap<Function>(F), ArgVec, EnvP);
}

LLVMGenericValueRef LLVM_STDCALL LLVMRunFunction(LLVMExecutionEngineRef EE, LLVMValueRef F,
                                    unsigned NumArgs,
                                    LLVMGenericValueRef *Args) {
  unwrap(EE)->finalizeObject();
  
  std::vector<GenericValue> ArgVec;
  ArgVec.reserve(NumArgs);
  for (unsigned I = 0; I != NumArgs; ++I)
    ArgVec.push_back(*unwrap(Args[I]));
  
  GenericValue *Result = new GenericValue();
  *Result = unwrap(EE)->runFunction(unwrap<Function>(F), ArgVec);
  return wrap(Result);
}

void LLVM_STDCALL LLVMFreeMachineCodeForFunction(LLVMExecutionEngineRef EE, LLVMValueRef F) {
}

void LLVM_STDCALL LLVMAddModule(LLVMExecutionEngineRef EE, LLVMModuleRef M){
  unwrap(EE)->addModule(std::unique_ptr<Module>(unwrap(M)));
}

LLVMBool LLVM_STDCALL LLVMRemoveModule(LLVMExecutionEngineRef EE, LLVMModuleRef M,
                          LLVMModuleRef *OutMod, char **OutError) {
  Module *Mod = unwrap(M);
  unwrap(EE)->removeModule(Mod);
  *OutMod = wrap(Mod);
  return 0;
}

LLVMBool LLVM_STDCALL LLVMFindFunction(LLVMExecutionEngineRef EE, const char *Name,
                          LLVMValueRef *OutFn) {
  if (Function *F = unwrap(EE)->FindFunctionNamed(Name)) {
    *OutFn = wrap(F);
    return 0;
  }
  return 1;
}

void *LLVM_STDCALL LLVMRecompileAndRelinkFunction(LLVMExecutionEngineRef EE,
                                     LLVMValueRef Fn) {
  return nullptr;
}

LLVMTargetDataRef LLVM_STDCALL LLVMGetExecutionEngineTargetData(LLVMExecutionEngineRef EE) {
  return wrap(&unwrap(EE)->getDataLayout());
}

LLVMTargetMachineRef LLVM_STDCALL 
LLVMGetExecutionEngineTargetMachine(LLVMExecutionEngineRef EE) {
  return wrap(unwrap(EE)->getTargetMachine());
}

void LLVM_STDCALL LLVMAddGlobalMapping(LLVMExecutionEngineRef EE, LLVMValueRef Global,
                          void* Addr) {
  unwrap(EE)->addGlobalMapping(unwrap<GlobalValue>(Global), Addr);
}

void *LLVM_STDCALL LLVMGetPointerToGlobal(LLVMExecutionEngineRef EE, LLVMValueRef Global) {
  unwrap(EE)->finalizeObject();
  
  return unwrap(EE)->getPointerToGlobal(unwrap<GlobalValue>(Global));
}

uint64_t LLVM_STDCALL LLVMGetGlobalValueAddress(LLVMExecutionEngineRef EE, const char *Name) {
  return unwrap(EE)->getGlobalValueAddress(Name);
}

uint64_t LLVM_STDCALL LLVMGetFunctionAddress(LLVMExecutionEngineRef EE, const char *Name) {
  return unwrap(EE)->getFunctionAddress(Name);
}

/*===-- Operations on memory managers -------------------------------------===*/

namespace {

struct SimpleBindingMMFunctions {
  LLVMMemoryManagerAllocateCodeSectionCallback AllocateCodeSection;
  LLVMMemoryManagerAllocateDataSectionCallback AllocateDataSection;
  LLVMMemoryManagerFinalizeMemoryCallback FinalizeMemory;
  LLVMMemoryManagerDestroyCallback Destroy;
};

class SimpleBindingMemoryManager : public RTDyldMemoryManager {
public:
  SimpleBindingMemoryManager(const SimpleBindingMMFunctions& Functions,
                             void *Opaque);
  ~SimpleBindingMemoryManager() override;

  uint8_t *allocateCodeSection(uintptr_t Size, unsigned Alignment,
                               unsigned SectionID,
                               StringRef SectionName) override;

  uint8_t *allocateDataSection(uintptr_t Size, unsigned Alignment,
                               unsigned SectionID, StringRef SectionName,
                               bool isReadOnly) override;

  bool finalizeMemory(std::string *ErrMsg) override;

private:
  SimpleBindingMMFunctions Functions;
  void *Opaque;
};

SimpleBindingMemoryManager::SimpleBindingMemoryManager(
  const SimpleBindingMMFunctions& Functions,
  void *Opaque)
  : Functions(Functions), Opaque(Opaque) {
  assert(Functions.AllocateCodeSection &&
         "No AllocateCodeSection function provided!");
  assert(Functions.AllocateDataSection &&
         "No AllocateDataSection function provided!");
  assert(Functions.FinalizeMemory &&
         "No FinalizeMemory function provided!");
  assert(Functions.Destroy &&
         "No Destroy function provided!");
}

SimpleBindingMemoryManager::~SimpleBindingMemoryManager() {
  Functions.Destroy(Opaque);
}

uint8_t *SimpleBindingMemoryManager::allocateCodeSection(
  uintptr_t Size, unsigned Alignment, unsigned SectionID,
  StringRef SectionName) {
  return Functions.AllocateCodeSection(Opaque, Size, Alignment, SectionID,
                                       SectionName.str().c_str());
}

uint8_t *SimpleBindingMemoryManager::allocateDataSection(
  uintptr_t Size, unsigned Alignment, unsigned SectionID,
  StringRef SectionName, bool isReadOnly) {
  return Functions.AllocateDataSection(Opaque, Size, Alignment, SectionID,
                                       SectionName.str().c_str(),
                                       isReadOnly);
}

bool SimpleBindingMemoryManager::finalizeMemory(std::string *ErrMsg) {
  char *errMsgCString = nullptr;
  bool result = Functions.FinalizeMemory(Opaque, &errMsgCString);
  assert((result || !errMsgCString) &&
         "Did not expect an error message if FinalizeMemory succeeded");
  if (errMsgCString) {
    if (ErrMsg)
      *ErrMsg = errMsgCString;
    free(errMsgCString);
  }
  return result;
}

} // anonymous namespace

LLVMMCJITMemoryManagerRef LLVM_STDCALL LLVMCreateSimpleMCJITMemoryManager(
  void *Opaque,
  LLVMMemoryManagerAllocateCodeSectionCallback AllocateCodeSection,
  LLVMMemoryManagerAllocateDataSectionCallback AllocateDataSection,
  LLVMMemoryManagerFinalizeMemoryCallback FinalizeMemory,
  LLVMMemoryManagerDestroyCallback Destroy) {
  
  if (!AllocateCodeSection || !AllocateDataSection || !FinalizeMemory ||
      !Destroy)
    return nullptr;
  
  SimpleBindingMMFunctions functions;
  functions.AllocateCodeSection = AllocateCodeSection;
  functions.AllocateDataSection = AllocateDataSection;
  functions.FinalizeMemory = FinalizeMemory;
  functions.Destroy = Destroy;
  return wrap(new SimpleBindingMemoryManager(functions, Opaque));
}

void LLVM_STDCALL LLVMDisposeMCJITMemoryManager(LLVMMCJITMemoryManagerRef MM) {
  delete unwrap(MM);
}
