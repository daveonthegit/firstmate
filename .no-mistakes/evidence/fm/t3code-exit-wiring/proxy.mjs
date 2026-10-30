import http from 'node:http';
import fs from 'node:fs';
let drop=true;
const server=http.createServer(async(req,res)=>{try{
 const chunks=[];for await(const x of req) chunks.push(x);const body=Buffer.concat(chunks);let d;try{d=JSON.parse(body)}catch{}
 const headers={...req.headers};delete headers.host;delete headers.connection;delete headers['content-length'];
 const upstream=await fetch('http://127.0.0.1:3773'+req.url,{method:req.method,headers,...(body.length?{body}:{})});
 const data=Buffer.from(await upstream.arrayBuffer());
 if(drop&&d?.params?.name==='t3_thread_session'){drop=false;console.log('Dropped committed stop reply: '+data.toString());res.destroy();return;}
 const outHeaders={};upstream.headers.forEach((v,k)=>{if(!['transfer-encoding','content-length','content-encoding'].includes(k))outHeaders[k]=v});
 res.writeHead(upstream.status,outHeaders);res.end(data);
}catch(e){res.writeHead(502);res.end(String(e))}});
server.listen(0,'127.0.0.1',()=>fs.writeFileSync('.test-t3-live/proxy-port',String(server.address().port)));
