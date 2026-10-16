// Runtime comparison, node-llama-cpp side. node bench-node-llama-cpp.mjs <model.gguf> <ctx> <cases.json> <n> <out.json>
// Needs node-llama-cpp installed (windows/node_modules). CPU only, greedy, the model card raw prompt.
import {getLlama, LlamaCompletion} from 'node-llama-cpp';
import fs from 'node:fs';
const SYS='You are a text normalizer for speech-to-text transcripts. The input begins with a control line specifying the styling, structure, and context settings; clean the transcript to match those settings and output only the cleaned text.';
const model_path=process.argv[2];
const ctxSize=Number(process.argv[3]||2048);
const cases=JSON.parse(fs.readFileSync(process.argv[4],'utf8')).slice(0,Number(process.argv[5]||40));
const rss=()=>Math.round(process.memoryUsage().rss/1048576);
const t0=performance.now();
const llama=await getLlama({gpu:false, build:'never', logLevel:'error'});
const model=await llama.loadModel({modelPath:model_path, useMmap:true});
const ctx=await model.createContext({contextSize:ctxSize, flashAttention:false, threads: Number(process.env.THREADS||0)});
const tLoad=performance.now()-t0;
console.log('load ms',Math.round(tLoad),'rss MB after load',rss());
const seq=ctx.getSequence();
const comp=new LlamaCompletion({contextSequence:seq});
const lat=[];const outs=[];
for(let i=0;i<cases.length+3;i++){
  const c=cases[i%cases.length];
  const prompt=`<|im_start|>system\n${SYS}<|im_end|>\n<|im_start|>user\n[Styling: semi-formal] [Structure: prose] [Context: general]\n${c.input}<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n`;
  const t=performance.now();
  const out=await comp.generateCompletion(prompt,{temperature:0, seed:0, maxTokens:undefined, customStopTriggers:undefined});
  const d=performance.now()-t; 
  
  if(i>=3){lat.push(d);outs.push({in:c.input,out})}
}
lat.sort((a,b)=>a-b);
const q=p=>Math.round(lat[Math.min(lat.length-1,Math.floor(p*lat.length))]);
console.log('n',lat.length,'median',q(.5),'p95',q(.95),'max',q(1),'rss MB end',rss());
fs.writeFileSync(process.argv[6]||'/dev/null',JSON.stringify(outs,null,1));
await model.dispose&&0;
