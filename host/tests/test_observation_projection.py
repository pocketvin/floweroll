import copy,json,unittest
from floweroll_host.observation_projection import project_observations
class ObservationProjectionTests(unittest.TestCase):
 def test_large_retrieval_is_projected_but_provenance_and_urls_survive(self):
  original=[{'action_id':'a','observation_id':'o','capability':'web.search','data':{'source_kind':'mcp','content':[{'type':'text','text':'https://example.com/source\n'+('detail '*10000)}]}}]
  untouched=copy.deepcopy(original);result=project_observations(original)
  self.assertEqual(original,untouched);self.assertEqual(result[0]['observation_id'],'o')
  self.assertIn('https://example.com/source',result[0]['data']['retrieved_urls'])
  self.assertTrue(result[0]['data']['truncated']);self.assertLess(len(json.dumps(result)),6500)
 def test_device_receipts_are_never_discarded_or_rewritten(self):
  original=[{'capability':'calendar.query','data':{'event_id':'real-event','verified':True}}]
  self.assertEqual(project_observations(original),original)
 def test_small_search_keeps_full_schema(self):
  original=[{'capability':'web.search','data':{'content':[{'type':'text','text':'small'}]}}]
  self.assertEqual(project_observations(original),original)
