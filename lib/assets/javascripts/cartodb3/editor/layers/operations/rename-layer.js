var Notifier = require('../../../components/notifier/notifier');
var errorParser = require('../../../helpers/error-parser');

module.exports = function (opts) {
  if (!opts.layerDefinitionModel) throw new Error('layerDefinitionModel is required');
  if (!opts.layerDefinitionsCollection) throw new Error('layerDefinitionsCollection is required');
  if (!opts.newName) throw new Error('newName is required');

  var layerDefinitionModel = opts.layerDefinitionModel;
  var layerDefinitionsCollection = opts.layerDefinitionsCollection;
  var successCallback = opts.onSuccess;
  var errorCallback = opts.onError;
  var newName = opts.newName;
  var oldName = layerDefinitionModel.getName();

  var notification = Notifier.addNotification({
    status: 'loading',
    info: _t('editor.layers.rename.loading'),
    closable: false
  });

  layerDefinitionModel.set({table_name_alias: newName});

  layerDefinitionsCollection.save({
    success: function () {
      successCallback && successCallback(newName);
      notification.set({
        status: 'success',
        info: _t('editor.layers.rename.success', {name: newName}),
        closable: true
      });
    },
    error: function (mdl, e) {
      errorCallback && errorCallback(oldName);
      notification.set({
        status: 'error',
        info: _t('editor.layers.rename.error', {name: oldName, error: errorParser(e)}),
        closable: true
      });
    }
  });
};