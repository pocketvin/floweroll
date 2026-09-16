from __future__ import annotations
import base64
import copy
import json
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
import uuid
from pathlib import Path
from floweroll_host.observation_service import (
    ObservationService, ObservationConflict, ObservationModelError, validate_summary, utcnow,
    fuse_echo_transcripts,
)
from floweroll_host.server import create_server


def uid(): return str(uuid.uuid4())


def configuration(sources=None, preset="meeting"):
    return {"id": uid(), "preset": preset, "sources": sources or ["ambientMicrophone"],
            "created_at": utcnow(), "consent_version": 1}


def event(source="ambientMicrophone", text="我们决定周二交付演示。", kind="transcript"):
    return {"id": uid(), "source": source, "kind": kind, "captured_at": utcnow(), "offset_ms": 1000,
            "duration_ms": 1000, "text": text}


class EvidenceOnlyModel:
    """Unit-test oracle only. Physical acceptance never injects this model."""
    ready = True
    def __init__(self): self.calls = []
    def __call__(self, *, events, notes, question=None, final=False):
        self.calls.append((events, notes, question, final))
        ids = [e["id"] for e in events] + [eid for n in notes for eid in n["evidence_ids"]]
        return {"title": "测试记录", "summary": "按提供的证据整理。", "evidence_ids": list(dict.fromkeys(ids)),
                "decisions": [], "todos": [], "open_questions": []}


class VisionEvidenceModel(EvidenceOnlyModel):
    def __init__(self):
        super().__init__(); self.vision_calls=[]
    def understand_screen(self,event):
        self.vision_calls.append(copy.deepcopy(event))
        return {"event_id":event["id"],"page_type":"job_detail","summary":"这是一个招聘职位详情页面，展示岗位要求与薪资信息。",
                "key_items":["AI Agent开发工程师","20-30K"],"visible_actions":["沟通"],"uncertainties":[]}


class RetryVisionModel(VisionEvidenceModel):
    def __init__(self):
        super().__init__(); self.vision_attempts=0
    def understand_screen(self,event):
        self.vision_attempts += 1
        if self.vision_attempts == 1:
            raise ObservationModelError("VISION_HTTP_429")
        return super().understand_screen(event)


class ObservationServiceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.now = [1000.0]
        self.model = EvidenceOnlyModel()
        self.service = ObservationService(str(Path(self.temp.name) / "tasks.sqlite3"), self.model, clock=lambda: self.now[0])
        self.config = configuration(); self.sid = self.config["id"]
        self.service.create(self.config)
    def tearDown(self):
        self.service.close(); self.temp.cleanup()
    def wait_analysis(self):
        until = time.monotonic() + 3
        while time.monotonic() < until:
            view = self.service.view(self.sid)
            if not view["analysis_running"]: return view
            time.sleep(.01)
        self.fail("analysis did not finish")
    def test_create_replay_and_configuration_conflict(self):
        self.assertEqual(self.service.create(self.config)["id"], self.sid)
        other = {**self.config, "preset": "custom", "sources": ["screen"]}
        with self.assertRaises(ObservationConflict): self.service.create(other)
    def test_permission_consent_required(self):
        for patch in ({"consent_version": 0}, {"sources": []}, {"sources": ["deviceAudio"]}, {"preset": "invalid"}):
            with self.subTest(patch=patch), self.assertRaises(ValueError):
                self.service.create({**configuration(), **patch})
    def test_all_seven_source_combinations(self):
        sources=["screen","ambientMicrophone","deviceAudio"]
        for mask in range(1,8):
            chosen=[s for i,s in enumerate(sources) if mask & (1<<i)]
            self.assertEqual(self.service.create(configuration(chosen,"custom"))["status"], "recording")
    def test_event_ack_exact_and_replay_does_not_duplicate(self):
        e=event();body={"events":[e]}
        self.assertEqual(self.service.ingest(self.sid,body)["acknowledged_ids"],[e["id"]])
        self.service.ingest(self.sid,body)
        self.assertEqual(self.service.view(self.sid)["event_count"],1)
        with self.assertRaises(ObservationConflict): self.service.ingest(self.sid,{"events":[{**e,"text":"changed"}]})
    def test_event_status_reconciles_exact_ids_without_reupload(self):
        existing=event();missing=event()
        self.service.ingest(self.sid,{"events":[existing]})
        status=self.service.event_status(self.sid,{"ids":[existing["id"],missing["id"]]})
        self.assertEqual(status["acknowledged_ids"],[existing["id"]])
        with self.assertRaises(ValueError):
            self.service.event_status(self.sid,{"ids":[existing["id"],existing["id"]]})

    def test_invalid_batch_is_atomic(self):
        e=event()
        with self.assertRaises(ValueError): self.service.ingest(self.sid,{"events":[e,event(source="screen",kind="screen")]})
        self.assertEqual(self.service.view(self.sid)["event_count"],0)
    def test_conflicting_duplicate_rolls_back_whole_batch(self):
        e=event();self.service.ingest(self.sid,{"events":[e]})
        with self.assertRaises(ObservationConflict):
            self.service.ingest(self.sid,{"events":[event(),{**e,"text":"different"}]})
        self.assertEqual(self.service.view(self.sid)["event_count"],1)
    def test_unselected_audio_and_invalid_frame_denied(self):
        for e in [event(source="deviceAudio"),event(source="system",kind="screen"),{**event(),"image_base64":"AAAA"},{**event(),"offset_ms":-1},{**event(),"captured_at":"2030-01-01T12:00:00"}]:
            with self.subTest(e=e),self.assertRaises(ValueError): self.service.ingest(self.sid,{"events":[e]})
    def test_checkpoint_not_triggered_until_internal_two_minutes(self):
        self.service.ingest(self.sid,{"events":[event()]})
        self.assertFalse(self.model.calls)
        self.now[0]+=119;self.service.schedule(self.sid);self.assertFalse(self.model.calls)
        self.now[0]+=1;self.service.schedule(self.sid)
        view=self.wait_analysis()
        self.assertEqual(len(view["notes"]),1)
        self.assertEqual(view["notes"][0]["kind"],"checkpoint")
        self.assertEqual(view["status"],"recording")
    def test_no_content_final_is_truthful_and_does_not_call_model(self):
        self.service.finish(self.sid,{"event_count":0});view=self.wait_analysis()
        self.assertEqual(view["status"],"completed")
        self.assertIn("没有采集",view["notes"][-1]["summary"])
        self.assertFalse(self.model.calls)
    def test_finish_requires_all_ack_and_seals_new_events(self):
        e=event();self.service.ingest(self.sid,{"events":[e]})
        with self.assertRaises(ObservationConflict): self.service.finish(self.sid,{"event_count":2})
        self.service.finish(self.sid,{"event_count":1});view=self.wait_analysis()
        self.assertEqual(view["status"],"completed")
        with self.assertRaises(ObservationConflict): self.service.ingest(self.sid,{"events":[event()]})
        self.assertEqual(self.service.ingest(self.sid,{"events":[e]})["session"]["event_count"],1)
        before=len(view["notes"]);self.service.finish(self.sid,{"event_count":1});self.wait_analysis()
        self.assertEqual(len(self.service.view(self.sid)["notes"]),before)
    def test_unknown_evidence_is_rejected(self):
        result=self.model(events=[event()],notes=[])
        with self.assertRaises(ObservationModelError): validate_summary(result,{uid()})
        result["evidence_ids"]=[]
        with self.assertRaises(ObservationModelError): validate_summary(result,{uid()})
    def test_model_failure_keeps_original_and_never_claims_completed(self):
        def failing(**kwargs): raise ObservationModelError("MODEL_CONNECTION_FAILED")
        self.service.model=failing
        e=event();self.service.ingest(self.sid,{"events":[e]})
        self.service.finish(self.sid,{"event_count":1});view=self.wait_analysis()
        self.assertEqual(view["status"],"analysis_failed")
        self.assertEqual(view["notes"],[])
        self.assertEqual(self.service.evidence(self.sid)["events"][0]["text"],e["text"])
        self.service.model=self.model
        self.service.schedule(self.sid,force=True)
        self.assertEqual(self.wait_analysis()["status"],"completed")
    def test_screen_image_removed_after_summary_but_original_replay_matches(self):
        config=configuration(["screen"],"screen");self.service.create(config);sid=config["id"]
        # Minimal test image envelope; actual provider test uses a real JPEG.
        e=event(source="screen",kind="screen");e["image_base64"]=base64.b64encode(b"\xff\xd8"+b"x"*16+b"\xff\xd9").decode()
        self.service.ingest(sid,{"events":[e]});self.service.finish(sid,{"event_count":1})
        for _ in range(300):
            if not self.service.view(sid)["analysis_running"]: break
            time.sleep(.01)
        with self.service.lock:
            raw=self.service.db.execute("SELECT data FROM observation_events WHERE session_id=?",(sid,)).fetchone()[0]
        self.assertNotIn("image_base64",raw)
        self.assertEqual(self.service.ingest(sid,{"events":[e]})["acknowledged_ids"],[e["id"]])
    def test_same_question_identity_no_duplicate_model_work(self):
        e=event();self.service.ingest(self.sid,{"events":[e]})
        q={"id":uid(),"question":"刚才决定了什么？"}
        self.service.ask(self.sid,q);self.service.ask(self.sid,q)
        for _ in range(300):
            values=self.service.view(self.sid)["questions"]
            if values and values[0]["status"]!="working": break
            time.sleep(.01)
        self.assertEqual(len(values),1);self.assertEqual(values[0]["status"],"completed")
    def test_deletion_fences_running_model_result(self):
        entered=threading.Event();release=threading.Event()
        original=self.model
        def blocked(**kwargs): entered.set();release.wait(3);return original(**kwargs)
        self.service.model=blocked
        self.service.ingest(self.sid,{"events":[event()]});self.service.finish(self.sid,{"event_count":1})
        self.assertTrue(entered.wait(1))
        self.service.delete(self.sid);release.set()
        time.sleep(.05)
        with self.assertRaises(KeyError): self.service.view(self.sid)
        with self.service.lock:
            self.assertEqual(self.service.db.execute("SELECT COUNT(*) FROM observation_notes").fetchone()[0],0)
    def test_deleted_session_cannot_be_resurrected_by_late_create(self):
        self.service.delete(self.sid)
        with self.assertRaises(ObservationConflict): self.service.create(self.config)

    def test_final_discloses_capture_gaps(self):
        self.service.ingest(self.sid,{"events":[event(),event(text="录音中断了十秒",kind="gap")]})
        self.service.finish(self.sid,{"event_count":2})
        self.assertIn("录音中断",self.wait_analysis()["notes"][-1]["summary"])

    def test_reopen_preserves_evidence_and_separate_task_database(self):
        e=event();self.service.ingest(self.sid,{"events":[e]})
        other=ObservationService(str(Path(self.temp.name)/"tasks.sqlite3"),self.model)
        try:
            self.assertEqual(other.evidence(self.sid)["events"][0]["id"],e["id"])
            self.assertFalse((Path(self.temp.name)/"tasks.sqlite3").exists())
        finally: other.close()
    def test_many_windows_all_enter_final_summary(self):
        for i in range(160): self.service.ingest(self.sid,{"events":[event(text="会议条目"+str(i))]})
        self.service.finish(self.sid,{"event_count":160});view=self.wait_analysis()
        self.assertEqual(view["status"],"completed")
        self.assertEqual(len(view["notes"][-1]["evidence_ids"]),160)

    def test_replayed_finish_does_not_bypass_model_backoff(self):
        calls=[]
        def failing(**kwargs):
            calls.append(kwargs)
            raise ObservationModelError("MODEL_HTTP_429")
        self.service.model=failing
        self.service.ingest(self.sid,{"events":[event()]})
        self.service.finish(self.sid,{"event_count":1})
        self.assertEqual(self.wait_analysis()["status"],"analysis_failed")
        for _ in range(6): self.service.finish(self.sid,{"event_count":1})
        self.assertEqual(len(calls),1)
        self.assertEqual(self.service.view(self.sid)["last_error"],"MODEL_HTTP_429")
        self.service.model=self.model
        self.service.schedule(self.sid,force=True)
        self.assertEqual(self.wait_analysis()["status"],"completed")

    def test_question_preserves_pending_image_only_evidence(self):
        config=configuration(["screen"],"screen");sid=config["id"];self.service.create(config)
        e=event(source="screen",kind="screen",text="")
        e["image_base64"]=base64.b64encode(b"\xff\xd8"+b"x"*16+b"\xff\xd9").decode()
        self.service.ingest(sid,{"events":[e]})
        self.service.ask(sid,{"id":uid(),"question":"刚刚的画面是什么？"})
        for _ in range(300):
            if self.service.view(sid)["questions"][0]["status"]!="working": break
            time.sleep(.01)
        args=self.model.calls[-1]
        self.assertEqual(args[0][0]["image_base64"],e["image_base64"])
        self.assertEqual(args[0][0]["id"],e["id"])

    def test_long_final_notes_are_compacted_in_bounded_groups(self):
        notes=[{"title":"阶段记录","summary":"内容"*1000,"evidence_ids":[uid()],
                "decisions":[],"todos":[],"open_questions":[]} for _ in range(70)]
        result=self.service._finalize_notes(notes)
        self.assertGreater(len(self.model.calls),1)
        self.assertEqual(set(result["evidence_ids"]),{i for n in notes for i in n["evidence_ids"]})
        for _,sent_notes,_,_ in self.model.calls:
            self.assertLess(len(json.dumps(sent_notes,ensure_ascii=False)),180000)


    def test_echo_fusion_prefers_device_audio_but_keeps_real_ambient_speech(self):
        device=event(source="deviceAudio",text="这个视频正在介绍新的算法能力。")
        device["offset_ms"]=35000;device["duration_ms"]=8000
        echo=event(source="ambientMicrophone",text="这个视频正在介绍新的算法能力")
        echo["offset_ms"]=35080;echo["duration_ms"]=7900
        user=event(source="ambientMicrophone",text="小卷帮我记一下这一点")
        user["offset_ms"]=44000;user["duration_ms"]=1800
        fused=fuse_echo_transcripts([echo,device,user])
        self.assertEqual([e["id"] for e in fused],[device["id"],user["id"]])

    def test_echo_fusion_matches_short_microphone_chunks_inside_long_device_audio(self):
        intro=event(source="ambientMicrophone",text="我们继续看视频吧，然后刚好是我们")
        intro["offset_ms"]=12999;intro["duration_ms"]=5520
        device=event(source="deviceAudio",text="好，然后刚好是我们。怎么把2026年9月这个周末两个看似矛盾的重磅信号同时在全球金融市场引爆。后面不是普通增资，而是一次关乎无数普通投资者系统性资产负债表的重构。今天我们不带任何情绪，只用客观数据，把藏在汇率与注资背后的宏观大账彻底算清楚。")
        device["offset_ms"]=13851;device["duration_ms"]=33480
        echo1=event(source="ambientMicrophone",text="2026年9月这个周末两个看似矛盾的重磅信号在全球金融市场引爆")
        echo1["offset_ms"]=18519;echo1["duration_ms"]=9240
        echo2=event(source="ambientMicrophone",text="不是普通增资而是一次关乎无数普通投资者系统性资产负债表的重构今天我们不带任何情绪只用客观数据把藏在汇率与注资背后的宏观大账彻底算清楚")
        echo2["offset_ms"]=38319;echo2["duration_ms"]=13200
        fused=fuse_echo_transcripts([intro,device,echo1,echo2])
        self.assertEqual([e["id"] for e in fused],[intro["id"],device["id"]])

    def test_screen_vlm_insight_is_durable_and_enters_summary_context(self):
        model=VisionEvidenceModel()
        service=ObservationService(str(Path(self.temp.name)/"vision.sqlite3"),model,clock=lambda:self.now[0])
        config=configuration(["screen"],"screen");sid=config["id"]
        service.create(config)
        try:
            frame=event(source="screen",kind="screen",text="AI Agent开发工程师 20-30K")
            frame["image_base64"]=base64.b64encode(b"\xff\xd8"+b"x"*32+b"\xff\xd9").decode()
            service.ingest(sid,{"events":[frame]})
            until=time.monotonic()+3
            view=service.view(sid)
            while time.monotonic()<until and not view["screen_insights"]:
                time.sleep(.01);view=service.view(sid)
            self.assertEqual(view["screen_insights"][0]["event_id"],frame["id"])
            self.assertIn("招聘职位详情",view["screen_insights"][0]["summary"])
            with service.lock:
                stored=json.loads(service.db.execute("SELECT data FROM observation_events WHERE session_id=? AND id=?",(sid,frame["id"])).fetchone()[0])
            self.assertNotIn("image_base64",stored)
            self.assertEqual(stored["screen_understanding"]["page_type"],"job_detail")
            self.now[0]+=120;service.schedule(sid)
            until=time.monotonic()+3
            while time.monotonic()<until and service.view(sid)["analysis_running"]: time.sleep(.01)
            self.assertTrue(model.calls)
            sent=model.calls[-1][0][0]
            self.assertEqual(sent["screen_understanding"]["page_type"],"job_detail")
        finally:
            service.close()

    def test_transient_vision_429_keeps_image_and_retries_after_backoff(self):
        model=RetryVisionModel()
        service=ObservationService(str(Path(self.temp.name)/"vision-retry.sqlite3"),model,clock=lambda:self.now[0])
        config=configuration(["screen"],"screen");sid=config["id"]
        service.create(config)
        try:
            frame=event(source="screen",kind="screen",text="视频画面中的桌面和人物")
            frame["image_base64"]=base64.b64encode(b"\xff\xd8"+b"r"*32+b"\xff\xd9").decode()
            service.ingest(sid,{"events":[frame]})
            until=time.monotonic()+3
            stored=None
            while time.monotonic()<until:
                with service.lock:
                    stored=json.loads(service.db.execute("SELECT data FROM observation_events WHERE session_id=? AND id=?",(sid,frame["id"])).fetchone()[0])
                if stored.get("screen_understanding_error")=="VISION_HTTP_429": break
                time.sleep(.01)
            self.assertEqual(stored.get("screen_understanding_error"),"VISION_HTTP_429")
            self.assertIn("image_base64",stored)
            self.assertGreater(stored.get("screen_understanding_retry_after",0),self.now[0])
            self.assertEqual(model.vision_attempts,1)
            service.view(sid);time.sleep(.03)
            self.assertEqual(model.vision_attempts,1)
            self.now[0]+=60
            service.view(sid)
            until=time.monotonic()+3
            view=service.view(sid)
            while time.monotonic()<until and not view["screen_insights"]:
                time.sleep(.01);view=service.view(sid)
            self.assertEqual(model.vision_attempts,2)
            self.assertEqual(view["screen_insights"][0]["event_id"],frame["id"])
            with service.lock:
                stored=json.loads(service.db.execute("SELECT data FROM observation_events WHERE session_id=? AND id=?",(sid,frame["id"])).fetchone()[0])
            self.assertNotIn("image_base64",stored)
            self.assertNotIn("screen_understanding_retry_after",stored)
            self.assertNotIn("screen_understanding_error",stored)
        finally:
            service.close()


class ObservationHTTPTests(unittest.TestCase):
    def test_auth_routing_and_normal_tasks_are_independent(self):
        with tempfile.TemporaryDirectory() as temp:
            server=create_server("127.0.0.1",0,str(Path(temp)/"host.db"),auth_token="test-observation-auth")
            thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
            base=f"http://127.0.0.1:{server.server_address[1]}"
            def request(path,body=None,auth=True):
                headers={"Content-Type":"application/json"}
                if auth: headers["Authorization"]="Bearer test-observation-auth"
                req=urllib.request.Request(base+path,data=json.dumps(body).encode() if body is not None else None,headers=headers)
                with urllib.request.urlopen(req,timeout=3) as r: return r.status,json.load(r)
            try:
                with self.assertRaises(urllib.error.HTTPError) as e: request("/v1/observations/health",auth=False)
                self.assertEqual(e.exception.code,401)
                status,health=request("/v1/observations/health");self.assertEqual(status,200)
                self.assertEqual(health["summary_interval_seconds"],120)
                config=configuration();sid=config["id"]
                request("/v1/observations/sessions",config)
                request(f"/v1/observations/sessions/{sid}/events",{"events":[event()]})
                _,view=request(f"/v1/observations/sessions/{sid}");self.assertEqual(view["event_count"],1)
                _, tasks = request("/v1/tasks?bucket=all")
                self.assertEqual(tasks.get("items", tasks.get("tasks", [])), [])
            finally:
                server.shutdown();server.server_close();thread.join(3)

if __name__=="__main__": unittest.main()
