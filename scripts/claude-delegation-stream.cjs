// Consume forwarded output in memory. No text, tool arguments, paths or raw
// records reach disk. Forwarding proves activity only, never completion.
const fs=require('node:fs'),path=require('node:path'),readline=require('node:readline');
const output=path.join(process.argv[2],'stream.jsonl');
const fd=fs.openSync(output,'wx',0o600);
const lines=readline.createInterface({input:process.stdin});
let failed=false;
lines.on('line', line => {
  try {
    const event=JSON.parse(line);
    if (event.type==='result' && event.is_error===true) failed=true;
    if (['assistant','user'].includes(event.type) && typeof event.parent_tool_use_id==='string'
      && /^[a-zA-Z0-9_-]{1,200}$/.test(event.parent_tool_use_id)) {
      fs.writeSync(fd,JSON.stringify({tool_use_id:event.parent_tool_use_id})+'\n');
    }
  } catch { failed=true; }
});
lines.on('close',()=>{fs.fsyncSync(fd);fs.closeSync(fd);if(failed)process.exitCode=1;});
