// % node --experimental-options --engine.CompileOnly=fib --engine.TraceCompilation --engine.MultiTier=false --engine.Inlining=false --vm.Dgraal.Dump=Truffle:1 --vm.Dgraal.PrintBackendCFG=true fib.js 14

function fib(n) {
  if (n <= 1) {
    return n;
  } else {
    return fib(n - 1) + fib(n - 2);
  }
}

while (true) {
  for (let n = 2; n < process.argv.length; n++) {
    fib(parseInt(process.argv[n]));
  }
}
