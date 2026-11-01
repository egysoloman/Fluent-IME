#!/usr/bin/env python3
"""Pinned open Chinese Transformer -> native Core ML candidate scoring model."""
import hashlib,json,os,shutil,time
from pathlib import Path
os.environ['HF_HUB_DISABLE_XET']='1'
import numpy as np
import torch
import coremltools as ct
from transformers import BertForMaskedLM, BertTokenizer
from huggingface_hub import snapshot_download
ROOT=Path(__file__).resolve().parent.parent
REV='0aa0527ff4170f29e1dfd3eb6ef60dc67e1bf75c'
source=snapshot_download('hfl/rbt3',revision=REV,token=False,allow_patterns=['config.json','pytorch_model.bin','vocab.txt','tokenizer_config.json','special_tokens_map.json','README.md'],local_dir=ROOT/'Vendor/rbt3')
model=BertForMaskedLM.from_pretrained(source,local_files_only=True,attn_implementation='eager',weights_only=True).eval()
torch.set_num_threads(4)
class TokenScorer(torch.nn.Module):
 def __init__(self,model):
  super().__init__(); self.bert=model.bert;self.cls=model.cls
 def forward(self,input_ids,attention_mask,positions,targets):
  embedded=self.bert.embeddings(input_ids=input_ids)
  additive=(1.0-attention_mask.float())[:,None,None,:] * -10000.0
  states=self.bert.encoder(embedded,attention_mask=additive,return_dict=False)[0]
  indices=positions[:,None,None].expand(-1,1,states.shape[-1])
  selected=torch.gather(states,1,indices).squeeze(1)
  scores=torch.log_softmax(self.cls(selected),dim=-1)
  return torch.gather(scores,1,targets[:,None]).squeeze(1)
wrapper=TokenScorer(model).eval()
example=(torch.ones((8,32),dtype=torch.int32),torch.ones((8,32),dtype=torch.int32),torch.ones(8,dtype=torch.int32),torch.ones(8,dtype=torch.int32))
# gather requires int64 in PyTorch, while Core ML interfaces remain int32.
class ExportScorer(TokenScorer):
 def forward(self,ids,mask,positions,targets):
  return super().forward(ids.long(),mask.long(),positions.long(),targets.long())
wrapper=ExportScorer(model).eval()
with torch.no_grad(): traced=torch.jit.trace(wrapper,example)
out=ROOT/'Resources/Models';out.mkdir(parents=True,exist_ok=True)
converted=ct.convert(traced,inputs=[ct.TensorType(name=name,shape=value.shape,dtype=np.int32) for name,value in zip(['input_ids','attention_mask','positions','targets'],example)],outputs=[ct.TensorType(name='token_scores',dtype=np.float32)],minimum_deployment_target=ct.target.macOS13,compute_precision=ct.precision.FLOAT16,convert_to='mlprogram',skip_model_load=True)
converted.author='HFL; Core ML conversion by Fluent IME'
converted.license='Apache-2.0'
converted.short_description='Chinese RBT3 masked-token log probabilities for candidate reranking'
converted.save(out/'RBT3Scorer.mlpackage')
shutil.copy2(Path(source)/'vocab.txt',out/'rbt3-vocab.txt')
shutil.copy2(Path(source)/'README.md',out/'RBT3-MODEL-CARD.md')
meta={'model':'hfl/rbt3','revision':REV,'license':'Apache-2.0','parameters':sum(p.numel() for p in model.parameters()),'batch':8,'sequence_length':32,'precision':'float16','torch':torch.__version__,'coremltools':ct.__version__}
(out/'rbt3-model.json').write_text(json.dumps(meta,indent=2)+'\n')
print(json.dumps(meta),flush=True)
# Validate converted math with a real Chinese masked-token batch.
tokenizer=BertTokenizer.from_pretrained(source,local_files_only=True)
encoded=tokenizer(['我想去北京'+tokenizer.mask_token]*8,padding='max_length',max_length=32,return_tensors='pt')
positions=(encoded['input_ids']==tokenizer.mask_token_id).int().argmax(dim=1).int()
targets=torch.tensor([tokenizer.convert_tokens_to_ids('旅')]*8,dtype=torch.int32)
args=(encoded['input_ids'].int(),encoded['attention_mask'].int(),positions,targets)
reference=wrapper(*args).detach().numpy()
inputs={k:v.numpy() for k,v in zip(['input_ids','attention_mask','positions','targets'],args)}
bench={}
for units in [ct.ComputeUnit.CPU_AND_GPU,ct.ComputeUnit.CPU_AND_NE,ct.ComputeUnit.CPU_ONLY]:
 start=time.perf_counter();cm=ct.models.MLModel(str(out/'RBT3Scorer.mlpackage'),compute_units=units)
 warm=cm.predict(inputs)['token_scores'];load=time.perf_counter()-start
 durations=[]
 for _ in range(12):
  start=time.perf_counter();actual=cm.predict(inputs)['token_scores'];durations.append((time.perf_counter()-start)*1000)
 error=float(np.max(np.abs(reference-actual)))
 bench[units.name]={'load_and_warm_seconds':load,'p50_ms':float(np.median(durations)),'p95_ms':float(np.percentile(durations,95)),'maximum_fp16_error':error}
 print(units.name,bench[units.name], 'reference', reference.tolist(), 'actual', actual.tolist(),flush=True)
 assert error<0.12,(units,error)
(ROOT/'artifacts/transformer-coreml-benchmark.json').write_text(json.dumps(bench,indent=2)+'\n')
