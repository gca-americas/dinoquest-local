



```
gcloud auth application-default login
```

```
python3 -c "
import json
with open('/Users/christina/.claude.json', 'r') as f:

    d = json.load(f)
    for k, v in d.get('projects', {}).items():
        if 'dino-local' in k:
            v['mcpServers']['google-bigquery']['oauth']['clientSecret'] = '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'
    with open('/Users/christina/.claude.json', 'w') as f:
        json.dump(d, f, indent=2)
    print('Done')                                                                                                
"      
```

URL for configuration reference
https://docs.cloud.google.com/mcp/configure-mcp-ai-application#gemini-cli