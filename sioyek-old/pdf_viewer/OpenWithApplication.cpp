#include <OpenWithApplication.h>

bool OpenWithApplication::event(QEvent *event) {
	if (event->type() == QEvent::FileOpen) {
		QFileOpenEvent *openEvent = static_cast<QFileOpenEvent *>(event);
		pending_file_name = openEvent->file();
		emit file_ready(openEvent->file());
	}

	return QApplication::event(event);
}
