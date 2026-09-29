const O="0x2cef85db37c28fccda8b409e2a321ee5932e1b292b596877184245972250004e";
const g=async q=>(await (await fetch("https://graphql.mainnet.sui.io/graphql",{method:"POST",headers:{"content-type":"application/json"},body:JSON.stringify({query:q})})).json());
const b=await g(`{address(address:"0xed6c5dccb7a79d39afbe498f9f7d7764cc343d4a45e1f8e97f4daeea0c2f79c2"){balance(coinType:"0x2::sui::SUI"){totalBalance}}}`);console.log("shield",b.data.address.balance.totalBalance/1e9);
const r=await g(`{events(filter:{type:"${O}::game::Deployed"},last:10){nodes{timestamp contents{json}}}}`);
for(const n of r.data.events.nodes){const j=n.contents.json;console.log(n.timestamp.slice(11,19),j.round_id,j.player.slice(0,8),Number(j.total)/1e9,j.amounts.filter(a=>+a>0).length)}
