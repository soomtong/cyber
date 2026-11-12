_ = Future.wait_any([]Future[int]{}.span())

--cytest: panic
--panic: No futures to wait for.
--
--[trace]
--