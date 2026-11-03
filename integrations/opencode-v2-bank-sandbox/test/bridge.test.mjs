import { test } from 'node:test'
import assert from 'node:assert/strict'
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, rmSync } from 'node:fs'
import { join, win32 } from 'node:path'
import { fileURLToPath } from 'node:url'
import { spawnSync } from 'node:child_process'
import { tmpdir } from 'node:os'
import { wrapShell } from '../index.js'

test('actual bridge confines commands and fails closed without readiness', {skip: !process.env.BANK_SANDBOX_EXE && 'set BANK_SANDBOX_EXE from a normal Windows host'}, () => {
  const parent = process.env.BANK_ADAPTER_TEST_ROOT || join(tmpdir(),'bank-adapter-bridge-tests')
  mkdirSync(parent,{recursive:true})
  const root = mkdtempSync(join(parent,'bridge-'))
  const workspace=join(root,'work'), controlDirectory=join(root,'control'), outside=join(root,'outside')
  for(const path of [workspace,controlDirectory,outside]) mkdirSync(path)
  const sandboxExe=process.env.BANK_SANDBOX_EXE
  const options={workspace,controlDirectory,sandboxExe}
  const secret=join(outside,'secret.txt'), target=join(outside,'created.txt')
  const marker='BRIDGE-'+crypto.randomUUID()
  writeFileSync(secret,marker)
  const call=(args)=>spawnSync(sandboxExe,args,{encoding:'utf8',timeout:30000,windowsHide:true})
  const bridge=(command)=>{
    const event={shell:win32.join(process.env.SystemRoot,'System32','WindowsPowerShell','v1.0','powershell.exe'),cwd:controlDirectory,command,timeout:15000}
    wrapShell(event,options)
    return spawnSync(event.shell,['-NoProfile','-NonInteractive','-Command',event.command],{cwd:event.cwd,env:event.env,encoding:'utf8',timeout:30000,windowsHide:true})
  }
  let prepared=false
  try{
    const ready=call(['prepare','--workspace',workspace]);assert.equal(ready.status,0,ready.stdout+ready.stderr);prepared=true
    const allowed=bridge(`Write-Output 'INSIDE-START'; Set-Content -LiteralPath '${join(workspace,'inside.txt')}' -Value 'inside-ok'`)
    assert.equal(allowed.status,0,allowed.stdout+allowed.stderr)
    assert.ok(existsSync(join(workspace,'inside.txt')), 'workspace file missing; bridge output: '+allowed.stdout+' stderr: '+allowed.stderr)
    assert.equal(readFileSync(join(workspace,'inside.txt'),'utf8').trim(),'inside-ok')
    const read=bridge(`Get-Content -LiteralPath '${secret}' -ErrorAction Stop`)
    assert.equal(read.status,1,read.stdout+read.stderr);assert.ok(!(read.stdout+read.stderr).includes(marker))
    const write=bridge(`Set-Content -LiteralPath '${target}' -Value 'breach' -ErrorAction Stop`)
    assert.equal(write.status,1,write.stdout+write.stderr);assert.equal(existsSync(target),false)
    const nested=bridge(`& $env:ComSpec /d /c 'type "${secret}"'`)
    assert.equal(nested.status,1,nested.stdout+nested.stderr);assert.ok(!(nested.stdout+nested.stderr).includes(marker))
    assert.equal(call(['remove','--workspace',workspace]).status,0);prepared=false
    const unavailable=bridge(`Set-Content -LiteralPath '${target}' -Value 'breach'`)
    assert.equal(unavailable.status,125,unavailable.stdout+unavailable.stderr);assert.equal(existsSync(target),false)
  }finally{
    if(prepared){const removed=call(['remove','--workspace',workspace]);if(removed.status!==0)throw new Error('fixture cleanup failed: '+removed.stderr)}
    rmSync(root,{recursive:true,force:true,maxRetries:10,retryDelay:200})
  }
})
